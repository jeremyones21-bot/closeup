import AppKit
import AVFoundation
import SwiftUI

/// Exports a project with the Quick Export settings, without opening the editor.
enum QuickExport {
    @MainActor
    static func run(_ project: ProjectFolder, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let log = project.loadCursor()
        let prefs = Prefs.shared
        var edits = project.loadEdits() ?? Edits()
        if project.loadEdits() == nil {
            let d = try await Render.sourceDuration(project)
            edits = EditorModel.initialEdits(samples: log?.decoded ?? [], duration: d, device: log?.device)
            project.save(edits)
        }
        let source = try await Render.source(project: project, cameraOffset: log?.cameraOffset, edits: edits)
        let natural = try await AVURLAsset(url: project.video).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            ?? CGSize(width: 1920, height: 1080)
        let samples = log?.decoded ?? []
        let motion = Motion(samples: samples, segments: edits.segments, style: edits.style, duration: source.sourceDuration,
                            hidden: edits.cursorHidden, loopEnd: min(edits.trimEnd ?? source.sourceDuration, source.sourceDuration),
                            loopStart: edits.trimStart)
        let display = log.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) } ?? CGSize(width: natural.width / 2, height: natural.height / 2)
        let comp = Compositor(style: edits.style, motion: motion, displayPoints: display)
        let offset = log?.cameraOffset ?? 0
        let faces = project.hasCamera && edits.style.faceTracking ? await Analyzer.cachedFaces(project, offset: offset) : []
        let silences = edits.style.hideCameraInSilence ? await Analyzer.cachedSilences(project) : []
        comp.update(style: edits.style, motion: motion,
                    scene: SceneData(crop: edits.crop, masks: edits.masks, layouts: edits.layouts, captions: project.loadCaptions(),
                                     shortcuts: log?.shortcuts ?? [], faces: faces, silences: silences))
        comp.setSuperResolution(prefs.superResolution)
        comp.setDevice(log?.device, hasCursor: !samples.isEmpty)
        let canvas = comp.canvas(source: natural, short: prefs.exportResolution)
        let vc = Render.composition(source: source, compositor: comp, canvas: canvas, fps: prefs.exportFPS)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: source.duration, preferredTimescale: 600))
        try await Exporter.export(asset: source.asset, composition: vc, audioMix: source.audioMix(volume: edits.volume), range: range,
                                  settings: .init(format: prefs.exportFormat, fps: prefs.exportFPS, compression: prefs.compression,
                                                  hevc: false, variableFrameRate: prefs.variableFrameRate),
                                  to: url, progress: progress)
    }

    static func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// Exports land here when they're only meant for the clipboard.
    static var clipboardFolder: URL {
        let dir = ProjectFolder.root.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Appears after a recording when "Show quick export widget" is on (or the after-recording
/// action is an export): copy, save, edit or discard the take.
@MainActor
final class QuickExportWidget {
    static let shared = QuickExportWidget()
    enum Action { case copy, save }
    private var panel: NSPanel?

    func show(project: ProjectFolder, autoStart: Action? = nil) {
        panel?.orderOut(nil)
        let model = QuickExportModel(project: project)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.title = project.name
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: QuickExportView(model: model, close: { [weak self] in self?.close() }))
        if let v = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: v.maxX - 380, y: v.minY + 20))
        }
        p.orderFrontRegardless()
        panel = p
        if let autoStart {
            Task { autoStart == .copy ? await model.copy() : await model.save() }
        }
    }

    func close() { panel?.orderOut(nil); panel = nil }
}

@MainActor
@Observable
final class QuickExportModel {
    let project: ProjectFolder
    var progress: Double?
    var message: String?
    var done: URL?

    init(project: ProjectFolder) { self.project = project }

    private var ext: String { Prefs.shared.exportFormat == .gif ? "gif" : "mp4" }

    func copy() async {
        let url = QuickExport.clipboardFolder.appendingPathComponent("\(project.name).\(ext)")
        if await export(to: url) {
            QuickExport.copyToClipboard(url)
            message = "Copied to the clipboard. Paste it anywhere."
        }
    }

    func save() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(ext)"
        panel.allowedContentTypes = [ext == "gif" ? .gif : .mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if await export(to: url) { message = "Saved." }
    }

    private func export(to url: URL) async -> Bool {
        progress = 0
        message = nil
        defer { progress = nil }
        do {
            try await QuickExport.run(project, to: url) { p in Task { @MainActor in self.progress = p } }
            done = url
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

private struct QuickExportView: View {
    @Bindable var model: QuickExportModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.progress {
                ProgressView(value: p) { Text("Exporting… \(Int(p * 100))%").monospacedDigit() }
            } else if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(Prefs.shared.exportFormat.label) · \(Int(Prefs.shared.exportResolution))p · \(Prefs.shared.exportFPS) fps · \(Prefs.shared.compression.label)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy") { Task { await model.copy() } }
                Button("Save…") { Task { await model.save() } }
                Button("Edit") {
                    NSApp.activate()
                    AppState.shared.openEditor?(model.project.url)
                    close()
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    AppState.shared.delete(model.project)
                    close()
                }
                .help("Move this recording to the Trash")
            }
            .disabled(model.progress != nil)
            if let url = model.done {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
