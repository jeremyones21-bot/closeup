import AVFoundation
import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

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
                List {
                    Section("Recordings") {
                        ForEach(app.projects) { p in
                            ProjectRow(project: p)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { openWindow(value: p.url) }
                                .contextMenu {
                                    Button("Open") { openWindow(value: p.url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { app.delete(p) }
                                }
                        }
                    }
                }
                .listStyle(.inset)
            }
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

struct ProjectRow: View {
    let project: ProjectFolder
    @State private var thumb: NSImage?
    @State private var length: Double?

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
        }
        .padding(.vertical, 2)
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
