import AVFoundation
import Observation
import SwiftUI

/// Timeline tracks, top to bottom.
enum Lane: String, CaseIterable, Identifiable {
    case zoom, clip, cursor, mask, layout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .clip: "Cut & Speed"
        case .cursor: "Cursor"
        case .mask: "Mask"
        case .layout: "Layout"
        }
    }
}

struct Selection: Equatable { var lane: Lane; var id: UUID }

@MainActor
@Observable
final class EditorModel {
    let project: ProjectFolder
    let player = AVPlayer()

    var loaded = false
    var loadError: String?
    /// Length of the original recording. The timeline is drawn in recording time.
    var duration: Double = 0
    /// Playhead, in recording time.
    var currentTime: Double = 0
    var playing = false
    var clicks: [Double] = []
    var selection: Selection?
    var hasCamera = false
    var isDevice = false
    var flags: [Double] = []
    var keys: [Double] = []
    var editedDuration: Double = 0
    var pickingFocus = false   // next click on the preview sets the selected zoom/mask point

    /// Results of on-device analysis (captions, faces, silences), filled in as they finish.
    var analysis = Analysis()
    struct Analysis: Equatable {
        var captions: [Caption] = []
        var faces: [FaceSample] = []
        var silences: [Span] = []
        var transcribing = false
        var transcriptError: String?
    }

    /// The starting look and zooms for a project opened for the first time.
    static func initialEdits(samples: [CursorSample], duration: Double, device: String?) -> Edits {
        var e = Edits()
        let prefs = Prefs.shared
        if let preset = PresetStore.defaultPreset() { e.style = preset.style }
        else if prefs.useLastProjectSettings, let last = prefs.lastStyle { e.style = last }
        if prefs.autoZooms, device == nil {
            e.segments = Motion.autoSegments(samples: samples, duration: duration)
        }
        return e
    }

    var edits = Edits() {
        didSet {
            guard loaded, edits != oldValue else { return }
            let timing = edits.cuts != oldValue.cuts || edits.speeds != oldValue.speeds
                || edits.trimStart != oldValue.trimStart || edits.trimEnd != oldValue.trimEnd
            let motionChanged = edits.segments != oldValue.segments || edits.cursorHidden != oldValue.cursorHidden
                || edits.style.cursorSmoothing != oldValue.style.cursorSmoothing || edits.style.hideIdleCursor != oldValue.style.hideIdleCursor
                || edits.style.loopCursor != oldValue.style.loopCursor || edits.trimEnd != oldValue.trimEnd
            let canvasChanged = edits.style.aspect != oldValue.style.aspect || edits.crop != oldValue.crop
            apply(motion: motionChanged, timing: timing, canvas: canvasChanged)
            if edits.volume != oldValue.volume { player.currentItem?.audioMix = source?.audioMix(volume: edits.volume) }
            scheduleSave()
            Prefs.shared.lastStyle = edits.style
        }
    }

    // Export
    var exporting = false
    var exportProgress: Double = 0
    var exportedURL: URL?
    var exportError: String?

    @ObservationIgnored private(set) var source: Render.Source!
    @ObservationIgnored private var samples: [CursorSample] = []
    @ObservationIgnored private(set) var sourceSize = CGSize(width: 1920, height: 1080)
    @ObservationIgnored private var displayPoints = CGSize(width: 1440, height: 900)
    @ObservationIgnored private(set) var compositor: Compositor!
    @ObservationIgnored private var motion: Motion!
    @ObservationIgnored private var composition: AVVideoComposition?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var log: CursorLog?
    @ObservationIgnored private var rebuilding: Task<Void, Never>?

    static let previewShort = 1080.0

    init(project: ProjectFolder) {
        self.project = project
    }

    var trimEnd: Double { min(edits.trimEnd ?? duration, duration) }
    var timeline: EditTimeline { source?.timeline ?? EditTimeline(edits: edits, sourceDuration: duration) }

    func load() async {
        guard !loaded else { return }
        let asset = AVURLAsset(url: project.video)
        do {
            duration = try await asset.load(.duration).seconds
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                sourceSize = CGSize(width: abs(size.width), height: abs(size.height))
            }
        } catch {
            loadError = "Couldn't open this recording: \(error.localizedDescription)"
            return
        }
        log = project.loadCursor()
        flags = log?.flags ?? []
        keys = log?.keys ?? []
        samples = log?.decoded ?? []
        displayPoints = log.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) }
            ?? CGSize(width: sourceSize.width / 2, height: sourceSize.height / 2)
        var wasDown = false
        clicks = samples.compactMap { s in
            defer { wasDown = s.down }
            return s.down && !wasDown ? s.t : nil
        }

        let isNew = project.loadEdits() == nil
        let e = project.loadEdits() ?? Self.initialEdits(samples: samples, duration: duration, device: log?.device)
        motion = makeMotion(e)
        compositor = Compositor(style: e.style, motion: motion, displayPoints: displayPoints)
        compositor.setDevice(log?.device, hasCursor: !samples.isEmpty)
        compositor.setSuperResolution(Prefs.shared.superResolution)
        isDevice = log?.device != nil
        edits = e
        compositor.update(style: e.style, motion: motion, scene: sceneData())
        analysis = Analysis(captions: project.loadCaptions())

        do {
            try await rebuildSource()
        } catch {
            loadError = "Couldn't open this recording: \(error.localizedDescription)"
            return
        }
        hasCamera = source.cameraTrack != nil
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        loaded = true
        if isNew { project.save(edits) }
        seek(to: edits.trimStart)
        Task { await Analyzer.run(for: self) }
    }

    private func makeMotion(_ e: Edits) -> Motion {
        Motion(samples: samples, segments: e.segments, style: e.style, duration: duration,
               hidden: e.cursorHidden, loopEnd: min(e.trimEnd ?? duration, duration), loopStart: e.trimStart)
    }

    func sceneData() -> SceneData {
        SceneData(crop: edits.crop, masks: edits.masks, layouts: edits.layouts, captions: analysis.captions,
                  shortcuts: log?.shortcuts ?? [], faces: analysis.faces, silences: analysis.silences)
    }

    /// Rebuilds the playable composition (after trims, cuts or speed changes) and keeps the playhead.
    private func rebuildSource() async throws {
        let keep = currentTime
        source = try await Render.source(project: project, cameraOffset: log?.cameraOffset, edits: edits)
        editedDuration = source.duration
        let canvas = compositor.canvas(source: sourceSize, short: Self.previewShort)
        composition = Render.composition(source: source, compositor: compositor, canvas: canvas)
        let item = AVPlayerItem(asset: source.asset)
        item.videoComposition = composition
        item.audioMix = source.audioMix(volume: edits.volume)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        if loaded { seek(to: min(max(keep, edits.trimStart), trimEnd)) }
    }

    private func tick(_ outputTime: Double) {
        currentTime = timeline.source(at: outputTime)
        playing = player.rate != 0
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            playing = false
        } else {
            if timeline.output(at: currentTime) >= editedDuration - 0.05 { seek(to: edits.trimStart) }
            player.play()
            playing = true
        }
    }

    /// Seek to a recording time. Cut-out moments land on the next kept moment.
    func seek(to t: Double) {
        let c = max(0, min(duration, t))
        currentTime = c
        // Seeking to the very end of the item (a trimmed-off moment maps there) shows black.
        let end = timeline.duration
        let out = min(timeline.output(at: c), max(0, end - 1.0 / 60))
        player.seek(to: CMTime(seconds: out, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Edits

    /// Set while a trim handle is being dragged. Swapping the player item on every drag tick
    /// blanks the preview, so the new timeline is built once, when the drag ends.
    var trimming = false {
        didSet { if oldValue && !trimming { apply(motion: false, timing: true, canvas: false) } }
    }

    private func apply(motion motionChanged: Bool, timing: Bool, canvas: Bool) {
        if motionChanged { motion = makeMotion(edits) }
        compositor.update(style: edits.style, motion: motion, scene: sceneData())
        if timing && trimming && !canvas {
            redrawPaused()
        } else if timing || canvas {
            rebuilding?.cancel()
            rebuilding = Task {
                try? await Task.sleep(for: .milliseconds(timing ? 120 : 0))   // coalesce drags
                guard !Task.isCancelled else { return }
                try? await rebuildSource()
            }
        } else {
            redrawPaused()
        }
    }

    func refreshScene() {
        compositor.update(style: edits.style, motion: motion, scene: sceneData())
        redrawPaused()
    }

    /// AVPlayer keeps showing a cached frame while paused; handing it a fresh copy of the
    /// composition makes it render the current frame again with the new look.
    private func redrawPaused() {
        guard let composition, player.rate == 0 else { return }
        player.currentItem?.videoComposition = composition.mutableCopy() as? AVVideoComposition
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let e = edits, p = project
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            p.save(e)
        }
    }

    // MARK: Tracks

    /// Spans of a lane as (id, start, end).
    func items(_ lane: Lane) -> [(id: UUID, start: Double, end: Double)] {
        switch lane {
        case .zoom: edits.segments.map { ($0.id, $0.start, $0.end) }
        case .clip: (edits.cuts + edits.speeds).map { ($0.id, $0.start, $0.end) }
        case .cursor: edits.cursorHidden.map { ($0.id, $0.start, $0.end) }
        case .mask: edits.masks.map { ($0.id, $0.start, $0.end) }
        case .layout: edits.layouts.map { ($0.id, $0.start, $0.end) }
        }
    }

    func label(_ lane: Lane, _ id: UUID) -> String {
        switch lane {
        case .zoom:
            guard let z = edits.segments.first(where: { $0.id == id }) else { return "" }
            return String(format: "%@%.1f×", z.kind == .loupe ? "Loupe " : "", z.scale)
        case .clip:
            if edits.cuts.contains(where: { $0.id == id }) { return "Cut" }
            return String(format: "%g×", edits.speeds.first { $0.id == id }?.rate ?? 1)
        case .cursor: return "Hidden"
        case .mask: return edits.masks.first { $0.id == id }?.kind.label ?? ""
        case .layout: return edits.layouts.first { $0.id == id }?.layout.label ?? ""
        }
    }

    func isCut(_ id: UUID) -> Bool { edits.cuts.contains { $0.id == id } }

    /// Adds an item to a lane at time t, fitted into the gap there.
    func add(_ lane: Lane, at t: Double, kind: String? = nil) {
        let existing = items(lane).sorted { $0.start < $1.start }
        if existing.contains(where: { t >= $0.start && t < $0.end }) { return }
        let before = existing.last { $0.end <= t }?.end ?? 0
        let after = existing.first { $0.start >= t }?.start ?? duration
        let len: Double = lane == .clip ? 1.5 : lane == .zoom ? 2.5 : 3
        let start = max(before, lane == .zoom ? t - 1 : t), end = min(after, start + len)
        guard end - start > 0.3 else { return }
        var id = UUID()
        switch lane {
        case .zoom:
            var z = ZoomSegment(start: start, end: end)
            if kind == "loupe" { z.kind = .loupe; z.scale = 2.5 }
            id = z.id
            edits.segments.append(z)
            edits.segments.sort { $0.start < $1.start }
        case .clip:
            if kind == "speed" {
                let s = Span(start: start, end: end, rate: 2)
                id = s.id; edits.speeds.append(s)
            } else {
                let s = Span(start: start, end: end)
                id = s.id; edits.cuts.append(s)
            }
        case .cursor:
            let s = Span(start: start, end: end); id = s.id; edits.cursorHidden.append(s)
        case .mask:
            let k = MaskKind(rawValue: kind ?? "") ?? .blur
            let s = Span(start: start, end: end, rect: CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.12), kind: k)
            id = s.id; edits.masks.append(s)
        case .layout:
            let s = Span(start: start, end: end, layout: CameraLayout(rawValue: kind ?? "") ?? .fullscreen)
            id = s.id; edits.layouts.append(s)
        }
        selection = Selection(lane: lane, id: id)
    }

    func deleteSelected() {
        guard let sel = selection else { return }
        switch sel.lane {
        case .zoom: edits.segments.removeAll { $0.id == sel.id }
        case .clip: edits.cuts.removeAll { $0.id == sel.id }; edits.speeds.removeAll { $0.id == sel.id }
        case .cursor: edits.cursorHidden.removeAll { $0.id == sel.id }
        case .mask: edits.masks.removeAll { $0.id == sel.id }
        case .layout: edits.layouts.removeAll { $0.id == sel.id }
        }
        selection = nil
    }

    /// Moves/resizes an item, keeping it inside the recording and off its neighbours in the lane.
    func setSpan(_ lane: Lane, _ id: UUID, start: Double, end: Double) {
        let all = items(lane)
        guard let me = all.first(where: { $0.id == id }) else { return }
        let others = all.filter { $0.id != id }
        let lo = others.filter { $0.end <= me.start + 0.001 }.map(\.end).max() ?? 0
        let hi = others.filter { $0.start >= me.end - 0.001 }.map(\.start).min() ?? duration
        var s = max(lo, start), e = min(hi, end)
        if e - s < 0.2 { if s == lo { e = s + 0.2 } else { s = e - 0.2 } }
        func upd(_ arr: inout [Span]) { if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].start = s; arr[i].end = e } }
        switch lane {
        case .zoom: if let i = edits.segments.firstIndex(where: { $0.id == id }) { edits.segments[i].start = s; edits.segments[i].end = e }
        case .clip: upd(&edits.cuts); upd(&edits.speeds)
        case .cursor: upd(&edits.cursorHidden)
        case .mask: upd(&edits.masks)
        case .layout: upd(&edits.layouts)
        }
    }

    var selectedZoom: ZoomSegment? {
        get { selection?.lane == .zoom ? edits.segments.first { $0.id == selection?.id } : nil }
        set { if let n = newValue, let i = edits.segments.firstIndex(where: { $0.id == n.id }) { edits.segments[i] = n } }
    }

    func selectedSpan(_ lane: Lane) -> Span? {
        guard let sel = selection, sel.lane == lane else { return nil }
        switch lane {
        case .clip: return (edits.cuts + edits.speeds).first { $0.id == sel.id }
        case .cursor: return edits.cursorHidden.first { $0.id == sel.id }
        case .mask: return edits.masks.first { $0.id == sel.id }
        case .layout: return edits.layouts.first { $0.id == sel.id }
        case .zoom: return nil
        }
    }

    func updateSpan(_ lane: Lane, _ span: Span) {
        func upd(_ arr: inout [Span]) { if let i = arr.firstIndex(where: { $0.id == span.id }) { arr[i] = span } }
        switch lane {
        case .clip: upd(&edits.cuts); upd(&edits.speeds)
        case .cursor: upd(&edits.cursorHidden)
        case .mask: upd(&edits.masks)
        case .layout: upd(&edits.layouts)
        case .zoom: break
        }
    }

    func duplicate(_ lane: Lane, _ id: UUID) {
        guard let item = items(lane).first(where: { $0.id == id }) else { return }
        let len = item.end - item.start
        let free = items(lane).filter { $0.start >= item.end }.map(\.start).min() ?? duration
        guard free - item.end >= min(len, 0.3) else { return }
        let start = item.end, end = min(free, item.end + len)
        switch lane {
        case .zoom:
            guard var z = edits.segments.first(where: { $0.id == id }) else { return }
            z.id = UUID(); z.start = start; z.end = end
            edits.segments.append(z); edits.segments.sort { $0.start < $1.start }
            selection = Selection(lane: lane, id: z.id)
        default:
            guard var sp = selectedSpanAny(lane, id) else { return }
            sp.id = UUID(); sp.start = start; sp.end = end
            switch lane {
            case .clip: if edits.speeds.contains(where: { $0.id == id }) { edits.speeds.append(sp) } else { edits.cuts.append(sp) }
            case .cursor: edits.cursorHidden.append(sp)
            case .mask: edits.masks.append(sp)
            case .layout: edits.layouts.append(sp)
            case .zoom: break
            }
            selection = Selection(lane: lane, id: sp.id)
        }
    }

    private func selectedSpanAny(_ lane: Lane, _ id: UUID) -> Span? {
        switch lane {
        case .clip: (edits.cuts + edits.speeds).first { $0.id == id }
        case .cursor: edits.cursorHidden.first { $0.id == id }
        case .mask: edits.masks.first { $0.id == id }
        case .layout: edits.layouts.first { $0.id == id }
        case .zoom: nil
        }
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let i = edits.segments.firstIndex(where: { $0.id == id }) else { return }
        change(&edits.segments[i])
    }

    func removeAll(_ lane: Lane) {
        switch lane {
        case .zoom: edits.segments = []
        case .clip: edits.cuts = []; edits.speeds = []
        case .cursor: edits.cursorHidden = []
        case .mask: edits.masks = []
        case .layout: edits.layouts = []
        }
        selection = nil
    }

    func regenerateZooms() {
        edits.segments = Motion.autoSegments(samples: samples, duration: duration)
        selection = nil
    }

    /// Speeds up stretches of steady typing (needs the key log, recorded with Accessibility on).
    func speedUpTyping() -> Int {
        let spans = Motion.typingSpans(keys: keys).filter { s in !edits.speeds.contains { $0.end > s.start && $0.start < s.end } }
        edits.speeds += spans
        return spans.count
    }

    /// Splits nothing; just a cut of `length` at the playhead, for the C key.
    func cutAtPlayhead() { add(.clip, at: currentTime) }

    // MARK: Preview mapping

    /// Maps a point in the preview's video rect (0–1, top-left) to the recording (0–1, top-left)
    /// at the current time, accounting for the zoom.
    func recordingPoint(fromPreview p: CGPoint) -> CGPoint? {
        let canvas = compositor.canvas(source: sourceSize, short: Self.previewShort)
        let v = compositor.view(at: currentTime, source: sourceSize, canvas: canvas)
        // Preview → canvas (bottom-left) → before-zoom canvas → screen-normalised.
        let cx = p.x * canvas.width, cy = (1 - p.y) * canvas.height
        let ux = cx / v.zoom + v.origin.x, uy = cy / v.zoom + v.origin.y
        var x = (ux - v.screen.minX) / v.screen.width
        var y = (v.screen.maxY - uy) / v.screen.height
        if let c = edits.crop { x = c.minX + x * c.width; y = c.minY + y * c.height }
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Recording rect (0–1) → preview rect (0–1, top-left), at the current time.
    func previewRect(fromRecording r: CGRect) -> CGRect {
        let canvas = compositor.canvas(source: sourceSize, short: Self.previewShort)
        let v = compositor.view(at: currentTime, source: sourceSize, canvas: canvas)
        var rr = r
        if let c = edits.crop {
            rr = CGRect(x: (r.minX - c.minX) / c.width, y: (r.minY - c.minY) / c.height, width: r.width / c.width, height: r.height / c.height)
        }
        let x0 = (v.screen.minX + rr.minX * v.screen.width - v.origin.x) * v.zoom
        let x1 = (v.screen.minX + rr.maxX * v.screen.width - v.origin.x) * v.zoom
        let yTop = (v.screen.maxY - rr.minY * v.screen.height - v.origin.y) * v.zoom
        let yBot = (v.screen.maxY - rr.maxY * v.screen.height - v.origin.y) * v.zoom
        return CGRect(x: x0 / canvas.width, y: 1 - yTop / canvas.height, width: (x1 - x0) / canvas.width, height: (yTop - yBot) / canvas.height)
    }

    var canvasAspect: Double {
        let c = compositor.canvas(source: sourceSize, short: Self.previewShort)
        return c.width / max(c.height, 1)
    }

    /// The current frame as an image, for Copy Frame.
    func currentFrameImage() async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: source.asset)
        gen.videoComposition = composition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: min(timeline.output(at: currentTime), max(0, timeline.duration - 1.0 / 60)), preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: t) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    // MARK: Export

    enum Resolution: Double, CaseIterable, Identifiable {
        case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
        var id: Double { rawValue }
        var label: String { self == .p2160 ? "4K" : "\(Int(rawValue))p" }
    }

    func export(resolution: Resolution, settings: Exporter.Settings, to url: URL) async {
        exporting = true
        exportProgress = 0
        exportError = nil
        exportedURL = nil
        defer { exporting = false }
        do {
            // GIFs: cap the size at 1080p and the frame rate at 30.
            let short = settings.format == .gif ? min(resolution.rawValue, 1080) : resolution.rawValue
            let fps = settings.format == .gif ? min(settings.fps, 30) : settings.fps
            let canvas = compositor.canvas(source: sourceSize, short: short)
            let comp = Render.composition(source: source, compositor: compositor, canvas: canvas, fps: fps)
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: source.duration, preferredTimescale: 600))
            var s = settings
            s.fps = fps
            try await Exporter.export(asset: source.asset, composition: comp, audioMix: source.audioMix(volume: edits.volume),
                                      range: range, settings: s, to: url) { p in
                Task { @MainActor in self.exportProgress = p }
            }
            exportedURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Set once the recording is in the Trash, so closing doesn't write edits.json back.
    var discarded = false

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        saveTask?.cancel()
        if loaded && !discarded { project.save(edits) }
    }
}
