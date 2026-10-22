import AVKit
import SwiftUI

struct EditorView: View {
    let project: ProjectFolder
    @State private var model: EditorModel
    @State private var showExport = false
    @State private var confirmTrash = false
    @State private var showCommands = false
    @State private var reelPreview: ReelOverlay.Kind = .off
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(project: ProjectFolder) {
        self.project = project
        _model = State(initialValue: EditorModel(project: project))
    }

    var body: some View {
        Group {
            if let err = model.loadError {
                ContentUnavailableView("Can't Open Recording", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        ToolRail(model: model)
                        VStack(spacing: 10) {
                            PreviewHeader(model: model)
                            PlayerView(player: model.player)
                                .overlay { PreviewOverlay(model: model, reel: reelPreview) }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            TransportBar(model: model)
                        }
                        Inspector(model: model)
                            .frame(width: 400)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    TimelineView(model: model)
                        .frame(height: model.timelineHeight)
                }
                .background(Studio.background)
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Command Menu…") { showCommands = true }
                    Button("Copy Frame") { Task { await copyFrame() } }
                    Picker("Social Preview", selection: $reelPreview) {
                        ForEach(ReelOverlay.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("Share Project…") { ProjectShare.export(project) }
                    Button("Restore Earlier Version…") { ProjectShare.restore(project) { model.edits = $0 } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    Divider()
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Studio.zoom)
                .disabled(!model.loaded)
                .keyboardShortcut("e", modifiers: .command)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $showCommands) {
            CommandMenu(model: model, export: { showExport = true }, copyFrame: { Task { await copyFrame() } })
        }
        .background {
            // ⌘K, like Screen Studio's command menu; ⇧⌘C copies the current frame.
            Button("") { showCommands = true }.keyboardShortcut("k", modifiers: .command).hidden()
            Button("") { Task { await copyFrame() } }.keyboardShortcut("c", modifiers: [.command, .shift]).hidden()
        }
        .confirmationDialog("Move \u{201C}\(project.name)\u{201D} to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                model.discarded = true
                model.close()
                app.delete(project)
                dismiss()
            }
        } message: {
            Text("The recording and its edits go to the Trash. You can put them back from there, or undo in the Closeup window.")
        }
        // Deleted from the recordings list while open here: close without saving.
        .onReceive(NotificationCenter.default.publisher(for: AppState.projectsTrashed)) { note in
            guard let urls = note.object as? [URL], urls.contains(project.url), !model.discarded else { return }
            model.discarded = true
            model.close()
            dismiss()
        }
        .task { await model.load() }
        .onDisappear { model.close() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.togglePlay()
            return .handled
        }
        .onKeyPress(.delete) {
            guard model.selection != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard model.selection != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
        .onKeyPress("z") { model.add(.zoom, at: model.currentTime); return .handled }
        .onKeyPress("c") { model.add(.clip, at: model.currentTime); return .handled }
        .onKeyPress(.leftArrow) { model.seek(to: model.currentTime - 1.0 / 30); return .handled }
        .onKeyPress(.rightArrow) { model.seek(to: model.currentTime + 1.0 / 30); return .handled }
    }

    private func copyFrame() async {
        guard let img = await model.currentFrameImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.allowsVideoFrameAnalysis = false
        // No black bars around the frame: the editor's own background shows through.
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            Text(timecode(model.timeline.output(at: model.currentTime)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Button { model.seek(to: model.edits.trimStart) } label: { Image(systemName: "backward.end") }
                .help("Go to start")
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.circle" : "play.circle").font(.system(size: 24, weight: .light))
            }
            .help("Play or pause (Space)")
            Button { model.seek(to: model.trimEnd) } label: { Image(systemName: "forward.end") }
                .help("Go to end")
            Text(timecode(model.editedDuration))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Spacer()
        }
        .font(.system(size: 16))
        .buttonStyle(.plain)
        .frame(height: 40)
    }
}

/// Colours of the dark editor.
enum Studio {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let panel = Color(red: 0.10, green: 0.10, blue: 0.115)
    static let stroke = Color.white.opacity(0.07)
    static let clip = Color(red: 0.86, green: 0.55, blue: 0.08)
    static let zoom = Color(red: 0.36, green: 0.31, blue: 0.95)
}

/// Tools down the left of the preview: add a zoom, loupe, cut, speed-up, hidden cursor, mask or
/// layout at the playhead.
struct ToolRail: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            tool("plus.magnifyingglass", "Add zoom at the playhead (Z)") { model.add(.zoom, at: model.currentTime) }
            tool("magnifyingglass.circle", "Add loupe at the playhead") { model.add(.zoom, at: model.currentTime, kind: "loupe") }
            Divider().frame(width: 28).padding(.vertical, 4)
            tool("scissors", "Cut at the playhead (C)") { model.add(.clip, at: model.currentTime) }
            tool("hare", "Speed up from the playhead") { model.add(.clip, at: model.currentTime, kind: "speed") }
            Divider().frame(width: 28).padding(.vertical, 4)
            tool("cursorarrow.slash", "Hide the cursor from the playhead") { model.add(.cursor, at: model.currentTime) }
            tool("eye.slash", "Blur part of the screen from the playhead") { model.add(.mask, at: model.currentTime, kind: MaskKind.blur.rawValue) }
            tool("highlighter", "Highlight part of the screen from the playhead") { model.add(.mask, at: model.currentTime, kind: MaskKind.highlight.rawValue) }
            if model.hasCamera {
                Divider().frame(width: 28).padding(.vertical, 4)
                tool("rectangle.split.2x1", "Change the camera layout from the playhead") { model.add(.layout, at: model.currentTime, kind: CameraLayout.split.rawValue) }
                tool("person.crop.rectangle", "Camera only from the playhead") { model.add(.layout, at: model.currentTime, kind: CameraLayout.fullscreen.rawValue) }
            }
        }
        .padding(.vertical, 12)
        .frame(width: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(Studio.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Studio.stroke))
        .padding(.top, 40)
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 40, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.85))
        .help(help)
    }
}

/// Above the preview: canvas shape and crop.
struct PreviewHeader: View {
    @Bindable var model: EditorModel
    @State private var showCrop = false

    var body: some View {
        HStack(spacing: 22) {
            Menu {
                Picker("Aspect", selection: $model.edits.style.aspect) {
                    ForEach(Aspect.allCases) { a in Text(a == .source ? "Auto" : a.label).tag(a) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.edits.style.aspect == .source ? "Auto" : model.edits.style.aspect.label, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { showCrop.toggle() } label: { Label("Crop", systemImage: "crop") }
                .buttonStyle(.plain)
                .popover(isPresented: $showCrop, arrowEdge: .bottom) {
                    Form { CropSection(model: model) }.formStyle(.grouped).frame(width: 320, height: 260)
                }
            Spacer()
        }
        .font(.system(size: 14))
        .frame(height: 30)
    }
}

func timecode(_ t: Double) -> String {
    let t = max(0, t)
    let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 10)
    return String(format: "%d:%02d.%d", m, s, cs)
}

// MARK: - Export

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var resolution = EditorModel.Resolution(rawValue: Prefs.shared.exportResolution) ?? .p1080
    @State private var format = Prefs.shared.exportFormat
    @State private var fps = Prefs.shared.exportFPS
    @State private var compression = Prefs.shared.compression
    @State private var hevc = false

    private var settings: Exporter.Settings {
        Exporter.Settings(format: format, fps: fps, compression: compression, hevc: hevc, variableFrameRate: Prefs.shared.variableFrameRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.headline)
            Form {
                Picker("Format", selection: $format) {
                    ForEach(Prefs.ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Resolution", selection: $resolution) {
                    ForEach(EditorModel.Resolution.allCases) { r in
                        Text(r.label).tag(r).disabled(format == .gif && r.rawValue > 1080)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Frame rate", selection: $fps) {
                    Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
                }
                if format == .mp4 {
                    Picker("Compression", selection: $compression) {
                        ForEach(Prefs.Compression.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("HEVC (smaller files, newer devices)", isOn: $hevc)
                } else {
                    Text("GIFs are capped at 1080p and 30 fps.").font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("Length", value: timecode(model.trimEnd - model.edits.trimStart))
            }
            .disabled(model.exporting)

            if model.exporting {
                ProgressView(value: model.exportProgress) {
                    Text("Exporting… \(Int(model.exportProgress * 100))%").monospacedDigit()
                }
            } else if let url = model.exportedURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } else if let err = model.exportError {
                Text(err).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button(model.exportedURL == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.exporting)
                Button("Copy to Clipboard") { copy() }
                    .disabled(model.exporting)
                Button("Export…") { choose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.exporting)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { model.exportedURL = nil; model.exportError = nil }
        .onChange(of: format) { if format == .gif && resolution.rawValue > 1080 { resolution = .p1080 } }
    }

    private var ext: String { format == .gif ? "gif" : "mp4" }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = model.project.name + "." + ext
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(resolution: resolution, settings: settings, to: url) }
    }

    private func copy() {
        let url = QuickExport.clipboardFolder.appendingPathComponent(model.project.name + "." + ext)
        Task {
            await model.export(resolution: resolution, settings: settings, to: url)
            if model.exportError == nil { QuickExport.copyToClipboard(url) }
        }
    }
}
