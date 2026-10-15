import AppKit
import AVFoundation
import SwiftUI

/// First-run window: asks for the permissions recording needs, one row at a time.
struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            VStack(spacing: 6) {
                Text("Welcome to Closeup").font(.largeTitle.weight(.bold))
                Text("Before you record, macOS needs to let Closeup see your screen.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 16) {
                row("Screen Recording", "Needed to record. You might need to reopen Closeup after allowing it.", granted: screen, required: true) {
                    if !CGRequestScreenCaptureAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                row("Accessibility", "Only for resizing a window to an exact size before recording. Optional.", granted: accessibility, required: false) {
                    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                }
                row("Camera", "Only if you want yourself in the video. Optional.", granted: camera, required: false) {
                    Task { camera = await AVCaptureDevice.requestAccess(for: .video) }
                }
                row("Microphone", "Only if you want to narrate. Optional.", granted: mic, required: false) {
                    Task { mic = await AVCaptureDevice.requestAccess(for: .audio) }
                }
            }
            .padding(.horizontal, 8)
            Text("Closeup collects no usage data. Recordings stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                UserDefaults.standard.set(true, forKey: "welcomed")
                dismissWindow(id: "welcome")
                AppState.shared.openHome?()
            } label: {
                Text("Continue").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(width: 600)
        .onReceive(tick) { _ in
            screen = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
        }
    }

    private func row(_ title: String, _ detail: String, granted: Bool, required: Bool, allow: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title + (required ? "" : "")).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 150)
            } else {
                Button("Allow \(title)", action: allow).frame(width: 150)
            }
        }
    }
}

/// The menu-bar icon. Its label view always exists, so it also hands AppState the window
/// actions (open the recordings window, an editor, or the welcome screen).
struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: app.phase == .recording ? "record.circle.fill" : "record.circle")
            .onAppear {
                app.openEditor = { openWindow(value: $0) }
                app.openHome = { openWindow(id: "home"); NSApp.activate() }
                app.openWelcome = { openWindow(id: "welcome"); NSApp.activate() }
                if !UserDefaults.standard.bool(forKey: "welcomed") || !CGPreflightScreenCaptureAccess() {
                    app.openWelcome?()
                }
                app.updateDockIcon()
            }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.phase == .recording {
            Button("Finish Recording") { Task { await app.stopRecording() } }
            Button(app.paused ? "Resume" : "Pause") { app.togglePause() }
            Button("Add Flag") { app.addFlag() }
            Divider()
        } else {
            Button("New Recording…") { app.showBar() }
            Divider()
        }
        Button("Open Closeup") { app.openHome?() }
        Button(SpeakerNotes.shared.isVisible ? "Hide Speaker Notes" : "Show Speaker Notes") { SpeakerNotes.shared.toggle() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Closeup") { NSApp.terminate(nil) }
    }
}
