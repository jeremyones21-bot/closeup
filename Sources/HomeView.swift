import AVFoundation
import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<URL>()

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("New Recording").font(.headline)
                    Spacer()
                    Button {
                        app.startRecording()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(app.phase != .idle || app.displays.isEmpty)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                HStack(spacing: 16) {
                    Picker("Display", selection: $app.displayID) {
                        ForEach(app.displays, id: \.displayID) { d in
                            Text(app.displayName(d)).tag(d.displayID)
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize()
                    .disabled(app.displays.isEmpty)
                    Toggle("Microphone", isOn: $app.microphone)
                }
                HStack(spacing: 16) {
                    Toggle("Camera", isOn: $app.camera)
                        .disabled(app.cameras.isEmpty)
                    if app.camera {
                        Picker("Camera", selection: $app.cameraID) {
                            ForEach(app.cameras, id: \.id) { c in Text(c.name).tag(Optional(c.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if app.cameras.isEmpty {
                        Text("No camera found").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Closeup hides itself and counts down from 3. Click the timer in the menu bar to stop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if app.needsPermission {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Closeup needs permission to record the screen.")
                            Text("Turn on Closeup in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen it.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        }
                    }
                }
                if let p = app.problem {
                    Text(p).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(16)

            Divider()

            if app.projects.isEmpty {
                ContentUnavailableView("No Recordings Yet", systemImage: "rectangle.dashed.badge.record",
                                       description: Text("Recordings are saved in Movies › Closeup."))
            } else {
                List(selection: $selection) {
                    Section("Recordings") {
                        ForEach(app.projects) { p in
                            ProjectRow(project: p, onDelete: { app.delete(p) })
                                .tag(p.url)
                        }
                    }
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    if urls.count == 1, let url = urls.first {
                        Button("Open") { openWindow(value: url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Divider()
                    }
                    if !urls.isEmpty {
                        Button(urls.count > 1 ? "Move \(urls.count) Recordings to Trash" : "Move to Trash", role: .destructive) {
                            app.delete(app.projects.filter { urls.contains($0.url) })
                            selection.subtract(urls)
                        }
                    }
                } primaryAction: { urls in
                    for url in urls { openWindow(value: url) }
                }
                .listStyle(.inset)
                // Delete key (and Edit › Delete) trashes whatever is selected.
                .onDeleteCommand { deleteSelection() }
            }

            if !app.lastTrashed.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text(app.lastTrashed.count == 1 ? "Moved 1 recording to the Trash." : "Moved \(app.lastTrashed.count) recordings to the Trash.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { app.undoDelete() }
                        .keyboardShortcut("z", modifiers: .command)
                    Button {
                        app.lastTrashed = []
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .onChange(of: app.projects) {
            selection.formIntersection(app.projects.map(\.url))
        }
        .onAppear {
            app.openEditor = { url in openWindow(value: url) }
            app.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refresh()
        }
    }
}

extension HomeView {
    func deleteSelection() {
        let targets = app.projects.filter { selection.contains($0.url) }
        guard !targets.isEmpty else { return }
        app.delete(targets)
        selection = []
    }
}

struct ProjectRow: View {
    let project: ProjectFolder
    var onDelete: () -> Void = {}
    @State private var thumb: NSImage?
    @State private var length: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                if let length {
                    Text(Duration.seconds(length).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Move to Trash")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .task(id: project.url) {
            let asset = AVURLAsset(url: project.video)
            length = try? await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.maximumSize = CGSize(width: 240, height: 150)
            gen.appliesPreferredTrackTransform = true
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                thumb = NSImage(cgImage: cg, size: .zero)
            }
        }
    }
}
