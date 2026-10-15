import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preview overlay (masks, zoom points, social preview)

/// Sits over the player. Lets you drag and resize the selected mask or highlight, pick a zoom's
/// fixed point, and shows Instagram / TikTok interface guides.
struct PreviewOverlay: View {
    @Bindable var model: EditorModel
    let reel: ReelOverlay.Kind
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let video = fit(aspect: model.canvasAspect, in: geo.size)
            ZStack(alignment: .topLeading) {
                if reel != .off {
                    ReelOverlay(kind: reel).frame(width: video.width, height: video.height).offset(x: video.minX, y: video.minY)
                        .allowsHitTesting(false)
                }
                if model.pickingFocus {
                    Color.black.opacity(0.15)
                        .frame(width: video.width, height: video.height).offset(x: video.minX, y: video.minY)
                        .overlay(alignment: .top) {
                            Text("Click where the zoom should point").font(.callout.weight(.medium))
                                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .offset(y: video.minY + 10)
                        }
                        .onTapGesture(coordinateSpace: .local) { p in
                            let n = CGPoint(x: (p.x - video.minX) / video.width, y: (p.y - video.minY) / video.height)
                            if let r = model.recordingPoint(fromPreview: n), var z = model.selectedZoom {
                                z.focus = r
                                model.selectedZoom = z
                            }
                            model.pickingFocus = false
                        }
                }
                if !model.playing, let m = model.selectedSpan(.mask), let r = m.rect,
                   model.currentTime >= m.start, model.currentTime < m.end {
                    maskBox(m, rect: r, video: video)
                }
            }
        }
    }

    private func fit(aspect: Double, in size: CGSize) -> CGRect {
        let w = min(size.width, size.height * aspect), h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func maskBox(_ m: Span, rect r: CGRect, video: CGRect) -> some View {
        let p = model.previewRect(fromRecording: r)
        let box = CGRect(x: video.minX + p.minX * video.width, y: video.minY + p.minY * video.height,
                         width: p.width * video.width, height: p.height * video.height)
        return ZStack(alignment: .bottomTrailing) {
            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(Color.accentColor.opacity(0.06))
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { v in move(m, r, video: video, translation: v.translation, resize: false) }
                    .onEnded { _ in dragStart = nil })
            Rectangle().fill(Color.accentColor).frame(width: 10, height: 10)
                .gesture(DragGesture().onChanged { v in move(m, r, video: video, translation: v.translation, resize: true) }
                    .onEnded { _ in dragStart = nil })
        }
        .frame(width: max(12, box.width), height: max(12, box.height))
        .offset(x: box.minX, y: box.minY)
    }

    /// Converts a drag on the preview into a new rectangle in recording coordinates.
    private func move(_ m: Span, _ r: CGRect, video: CGRect, translation t: CGSize, resize: Bool) {
        if dragStart == nil { dragStart = r }
        guard let start = dragStart else { return }
        let p0 = model.previewRect(fromRecording: start)
        let scaleX = start.width / max(p0.width, 0.0001) / video.width
        let scaleY = start.height / max(p0.height, 0.0001) / video.height
        var n = start
        if resize {
            n.size.width = max(0.02, start.width + t.width * scaleX)
            n.size.height = max(0.02, start.height + t.height * scaleY)
        } else {
            n.origin.x = min(max(0, start.minX + t.width * scaleX), 1 - start.width)
            n.origin.y = min(max(0, start.minY + t.height * scaleY), 1 - start.height)
        }
        var s = m
        s.rect = n
        model.updateSpan(.mask, s)
    }
}

/// Approximations of where Instagram Reels and TikTok put their buttons and captions, so you can
/// keep important things clear of them. Shown in the editor only, never exported.
struct ReelOverlay: View {
    enum Kind: String, CaseIterable, Identifiable {
        case off, instagram, tiktok
        var id: String { rawValue }
        var label: String { self == .off ? "Off" : self == .instagram ? "Instagram Reels" : "TikTok" }
    }
    let kind: Kind

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                // Bottom caption / account area.
                Rectangle().fill(Color.black.opacity(0.35))
                    .frame(width: w, height: h * (kind == .tiktok ? 0.22 : 0.2)).offset(y: h * (kind == .tiktok ? 0.78 : 0.8))
                // Right-hand action buttons.
                VStack(spacing: h * 0.03) {
                    ForEach(0..<(kind == .tiktok ? 5 : 4), id: \.self) { _ in
                        Circle().fill(Color.white.opacity(0.55)).frame(width: w * 0.08, height: w * 0.08)
                    }
                }
                .offset(x: w * 0.88, y: h * (kind == .tiktok ? 0.42 : 0.5))
                // Top bar.
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: w, height: h * 0.08)
                Text(kind.label).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(6)
            }
        }
    }
}

// MARK: - Command menu (⌘K)

struct CommandMenu: View {
    @Bindable var model: EditorModel
    let export: () -> Void
    let copyFrame: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Command: Identifiable { let id = UUID(); let title: String; let symbol: String; let run: () -> Void }

    private var commands: [Command] {
        let m = model
        var list: [Command] = [
            Command(title: "Add Zoom", symbol: "plus.magnifyingglass") { m.add(.zoom, at: m.currentTime) },
            Command(title: "Add Loupe Zoom", symbol: "magnifyingglass.circle") { m.add(.zoom, at: m.currentTime, kind: "loupe") },
            Command(title: "Cut Here", symbol: "scissors") { m.add(.clip, at: m.currentTime) },
            Command(title: "Speed Up Here", symbol: "hare") { m.add(.clip, at: m.currentTime, kind: "speed") },
            Command(title: "Add Blur Mask", symbol: "eye.slash") { m.add(.mask, at: m.currentTime, kind: "blur") },
            Command(title: "Add Highlight", symbol: "rectangle.dashed") { m.add(.mask, at: m.currentTime, kind: "highlight") },
            Command(title: "Hide Cursor Here", symbol: "cursorarrow.slash") { m.add(.cursor, at: m.currentTime) },
            Command(title: "Redo Zooms from Clicks", symbol: "wand.and.stars") { m.regenerateZooms() },
            Command(title: "Speed Up Typing", symbol: "keyboard") { _ = m.speedUpTyping() },
            Command(title: "Toggle Captions", symbol: "captions.bubble") { m.edits.style.captions.toggle() },
            Command(title: "Toggle Motion Blur", symbol: "wind") { m.edits.style.motionBlur.toggle() },
            Command(title: "Toggle Click Sounds", symbol: "speaker.wave.2") { m.edits.style.clickSound.toggle() },
            Command(title: "Toggle Keyboard Shortcuts", symbol: "command") { m.edits.style.showShortcuts.toggle() },
            Command(title: "Copy Frame", symbol: "photo.on.rectangle") { copyFrame() },
            Command(title: "Export…", symbol: "square.and.arrow.up") { export() },
        ]
        for a in Aspect.allCases { list.append(Command(title: "Aspect \(a.label)", symbol: "aspectratio") { m.edits.style.aspect = a }) }
        for b in Backdrop.allCases { list.append(Command(title: "Backdrop \(b.label)", symbol: "paintpalette") { m.edits.style.backdrop = b }) }
        if m.hasCamera {
            for l in CameraLayout.allCases { list.append(Command(title: "Layout: \(l.label) Here", symbol: "rectangle.split.2x1") {
                m.add(.layout, at: m.currentTime, kind: l.rawValue) }) }
        }
        return list
    }

    private var matches: [Command] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? commands : commands.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14)
                .focused($focused)
                .onSubmit { if let c = matches.first { run(c) } }
            Divider()
            List(matches) { c in
                Button { run(c) } label: { Label(c.title, systemImage: c.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 460, height: 380)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func run(_ c: Command) {
        dismiss()
        c.run()
    }
}

// MARK: - Project sharing, versions, import

enum ProjectShare {
    /// Zips the whole project (recording, camera, edits, captions) so someone else can keep editing.
    @MainActor
    static func export(_ p: ProjectFolder) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).closeup.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", p.url.path, url.path])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a project someone shared (a .closeup.zip) into the recordings folder.
    @MainActor
    static func importShared() -> ProjectFolder? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let before = Set(ProjectFolder.all().map(\.url))
        run("/usr/bin/ditto", ["-x", "-k", url.path, ProjectFolder.root.path])
        return ProjectFolder.all().first { !before.contains($0.url) }
    }

    /// Makes a project from an existing video file. Most of the look (backdrop, zooms, captions)
    /// works; cursor effects don't, since there's no cursor log.
    @MainActor
    static func importVideo() -> ProjectFolder? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let p = ProjectFolder.makeNew(name: url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension.lowercased() == "mov" ? "mov" : url.pathExtension.lowercased()
        try? FileManager.default.copyItem(at: url, to: p.url.appendingPathComponent("screen.\(ext)"))
        return p
    }

    @MainActor
    static func restore(_ p: ProjectFolder, apply: (Edits) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = p.versionsFolder
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an earlier version of the edits to go back to."
        guard panel.runModal() == .OK, let url = panel.url,
              let e = try? JSONDecoder().decode(Edits.self, from: Data(contentsOf: url)) else { return }
        apply(e)
    }

    private static func run(_ path: String, _ args: [String]) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        try? t.run()
        t.waitUntilExit()
    }
}
