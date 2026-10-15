import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorModel {
    let project: ProjectFolder
    let player = AVPlayer()

    var loaded = false
    var loadError: String?
    var duration: Double = 0
    var currentTime: Double = 0
    var playing = false
    var clicks: [Double] = []
    var selected: UUID?
    var hasCamera = false
    var isDevice = false
    var flags: [Double] = []

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
            apply(styleOnly: edits.segments == oldValue.segments && edits.style.cursorSmoothing == oldValue.style.cursorSmoothing
                  && edits.style.hideIdleCursor == oldValue.style.hideIdleCursor,
                  aspectChanged: edits.style.aspect != oldValue.style.aspect)
            scheduleSave()
            Prefs.shared.lastStyle = edits.style
        }
    }

    // Export
    var exporting = false
    var exportProgress: Double = 0
    var exportedURL: URL?
    var exportError: String?

    @ObservationIgnored private var asset: AVURLAsset!
    @ObservationIgnored private var source: Render.Source!
    @ObservationIgnored private var samples: [CursorSample] = []
    @ObservationIgnored private var sourceSize = CGSize(width: 1920, height: 1080)
    @ObservationIgnored private var displayPoints = CGSize(width: 1440, height: 900)
    @ObservationIgnored private var compositor: Compositor!
    @ObservationIgnored private var motion: Motion!
    @ObservationIgnored private var composition: AVVideoComposition?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static let previewShort = 1080.0

    init(project: ProjectFolder) {
        self.project = project
    }

    var trimEnd: Double { min(edits.trimEnd ?? duration, duration) }

    func load() async {
        guard !loaded else { return }
        asset = AVURLAsset(url: project.video)
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
        let log = project.loadCursor()
        do {
            source = try await Render.source(project: project, cameraOffset: log?.cameraOffset)
        } catch {
            loadError = "Couldn't open this recording: \(error.localizedDescription)"
            return
        }
        hasCamera = source.cameraTrack != nil
        flags = log?.flags ?? []
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
        motion = Motion(samples: samples, segments: e.segments, style: e.style, duration: duration)
        compositor = Compositor(style: e.style, motion: motion, displayPoints: displayPoints)
        compositor.update(style: e.style, motion: motion)
        compositor.setDevice(log?.device, hasCursor: !samples.isEmpty)
        isDevice = log?.device != nil
        edits = e

        await rebuildComposition()
        let item = AVPlayerItem(asset: source.asset)
        item.videoComposition = composition
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        loaded = true
        if isNew { project.save(edits) }
        seek(to: edits.trimStart)
    }

    private func tick(_ t: Double) {
        currentTime = t
        playing = player.rate != 0
        if playing, t >= trimEnd - 0.01 {
            player.pause()
            playing = false
        }
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            playing = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < edits.trimStart { seek(to: edits.trimStart) }
            player.play()
            playing = true
        }
    }

    func seek(to t: Double) {
        let c = max(0, min(duration, t))
        currentTime = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Edits

    private func apply(styleOnly: Bool, aspectChanged: Bool) {
        if !styleOnly {
            motion = Motion(samples: samples, segments: edits.segments, style: edits.style, duration: duration)
        }
        compositor.update(style: edits.style, motion: motion)
        if aspectChanged {
            Task {
                await rebuildComposition()
                player.currentItem?.videoComposition = composition
            }
        } else {
            redrawPaused()
        }
    }

    /// AVPlayer keeps showing a cached frame while paused; handing it a fresh copy of the
    /// composition makes it render the current frame again with the new look.
    private func redrawPaused() {
        guard let composition, player.rate == 0 else { return }
        player.currentItem?.videoComposition = composition.mutableCopy() as? AVVideoComposition
    }

    private func rebuildComposition() async {
        let canvas = compositor.canvas(source: sourceSize, short: Self.previewShort)
        composition = Render.composition(source: source, compositor: compositor, canvas: canvas)
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

    var selectedSegment: ZoomSegment? {
        get { edits.segments.first { $0.id == selected } }
        set {
            guard let newValue, let i = edits.segments.firstIndex(where: { $0.id == newValue.id }) else { return }
            edits.segments[i] = newValue
        }
    }

    /// Adds a zoom centred on `t`, fitted into whatever gap is there.
    func addSegment(at t: Double) {
        let sorted = edits.segments.sorted { $0.start < $1.start }
        let before = sorted.last { $0.end <= t }?.end ?? 0
        let after = sorted.first { $0.start >= t }?.start ?? duration
        if sorted.contains(where: { t >= $0.start && t < $0.end }) { return }
        let start = max(before, t - 1.0), end = min(after, t + 1.5)
        guard end - start > 0.3 else { return }
        let seg = ZoomSegment(start: start, end: end)
        edits.segments.append(seg)
        edits.segments.sort { $0.start < $1.start }
        selected = seg.id
    }

    func deleteSelected() {
        guard let selected else { return }
        edits.segments.removeAll { $0.id == selected }
        self.selected = nil
    }

    func regenerateZooms() {
        edits.segments = Motion.autoSegments(samples: samples, duration: duration)
        selected = nil
    }

    /// Moves/resizes a segment, keeping it inside the recording and off its neighbours.
    func setSegment(_ id: UUID, start: Double, end: Double) {
        guard let i = edits.segments.firstIndex(where: { $0.id == id }) else { return }
        let others = edits.segments.filter { $0.id != id }
        let lo = others.filter { $0.end <= edits.segments[i].start + 0.001 }.map(\.end).max() ?? 0
        let hi = others.filter { $0.start >= edits.segments[i].end - 0.001 }.map(\.start).min() ?? duration
        var s = max(lo, start), e = min(hi, end)
        if e - s < 0.3 {
            if s == lo { e = s + 0.3 } else { s = e - 0.3 }
        }
        edits.segments[i].start = s
        edits.segments[i].end = e
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
            let range = CMTimeRange(start: CMTime(seconds: edits.trimStart, preferredTimescale: 600),
                                    end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            var s = settings
            s.fps = fps
            try await Exporter.export(asset: source.asset, composition: comp, range: range, settings: s, to: url) { p in
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
