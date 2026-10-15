import AVKit
import SwiftUI

struct EditorView: View {
    let project: ProjectFolder
    @State private var model: EditorModel
    @State private var showExport = false

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
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PlayerView(player: model.player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(nsColor: .underPageBackgroundColor))
                        Divider()
                        TransportBar(model: model)
                        Divider()
                        TimelineView(model: model)
                            .frame(height: 96)
                    }
                    Divider()
                    Inspector(model: model)
                        .frame(width: 300)
                }
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.loaded)
                .keyboardShortcut("e", modifiers: .command)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
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
            guard model.selected != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard model.selected != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
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
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Play or pause (Space)")

            Text("\(timecode(model.currentTime)) / \(timecode(model.trimEnd - model.edits.trimStart))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text("Double-click the zoom track to add a zoom. Drag its edges to adjust.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
    @State private var resolution = EditorModel.Resolution.p1080
    @State private var codec = Render.Codec.h264

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.headline)
            Form {
                Picker("Resolution", selection: $resolution) {
                    ForEach(EditorModel.Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Format", selection: $codec) {
                    ForEach(Render.Codec.allCases) { Text($0.label).tag($0) }
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
                Button("Export…") { choose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.exporting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { model.exportedURL = nil; model.exportError = nil }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.project.name + ".mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(resolution: resolution, codec: codec, to: url) }
    }
}
