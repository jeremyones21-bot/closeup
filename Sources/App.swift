import AVFoundation
import ScreenCaptureKit
import SwiftUI

@main
struct CloseupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("Closeup", id: "home") {
            HomeView()
                .environment(app)
                .onAppear { delegate.app = app }
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 640, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { app.startRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(app.phase != .idle)
            }
        }

        WindowGroup("Editor", for: URL.self) { $url in
            if let url {
                EditorView(project: ProjectFolder(url: url))
                    .environment(app)
                    .frame(minWidth: 980, minHeight: 620)
            }
        }
        .defaultSize(width: 1280, height: 820)
    }
}

/// Recording state, the take list, and the menu-bar control used while recording.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable { case idle, countdown(Int), recording, saving }

    var phase: Phase = .idle
    var projects: [ProjectFolder] = ProjectFolder.all()
    var displays: [SCDisplay] = []
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var microphone = false
    var camera = false
    var cameraID: String?
    var cameras: [(id: String, name: String)] = []
    var problem: String?
    var needsPermission = false

    /// Set by a view that has the openWindow action.
    var openEditor: ((URL) -> Void)?

    private var recorder: Recorder?
    private var statusItem: NSStatusItem?
    private var started = Date()
    private var ticker: Timer?

    func refresh() {
        projects = ProjectFolder.all()
        cameras = CameraRecorder.devices().map { ($0.uniqueID, $0.localizedName) }
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) { cameraID = nil }
        if cameraID == nil { cameraID = cameras.first?.id }
        Task {
            do {
                displays = try await Recorder.displays()
                needsPermission = false
                if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? CGMainDisplayID() }
            } catch {
                needsPermission = true
            }
        }
    }

    func displayName(_ d: SCDisplay) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
        }
        return "\(screen?.localizedName ?? "Display") — \(d.width)×\(d.height)"
    }

    func startRecording() {
        guard phase == .idle else { return }
        problem = nil
        if camera {
            Task {
                guard await CameraRecorder.requestAccess() else {
                    problem = "Closeup can't use the camera. Turn it on in System Settings › Privacy & Security › Camera, or switch Camera off."
                    return
                }
                beginCountdown()
            }
        } else {
            beginCountdown()
        }
    }

    private func beginCountdown() {
        showStatusItem()
        NSApp.hide(nil)
        phase = .countdown(3)
        updateStatus()
        Task {
            for n in [2, 1] {
                try? await Task.sleep(for: .seconds(1))
                guard case .countdown = phase else { return }
                phase = .countdown(n)
                updateStatus()
            }
            try? await Task.sleep(for: .seconds(1))
            guard case .countdown = phase else { return }
            await beginCapture()
        }
    }

    private func beginCapture() async {
        let rec = Recorder()
        rec.onStreamError = { [weak self] error in
            Task { @MainActor in
                self?.problem = "Recording stopped: \(error.localizedDescription)"
                await self?.stopRecording()
            }
        }
        do {
            try await rec.start(displayID: displayID, microphone: microphone,
                                camera: camera ? .some(cameraID) : nil, into: .makeNew())
            recorder = rec
            started = .now
            phase = .recording
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
            updateStatus()
        } catch {
            fail(error)
        }
    }

    func stopRecording() async {
        switch phase {
        case .countdown:
            phase = .idle
            removeStatusItem()
            NSApp.unhide(nil)
            return
        case .recording:
            break
        default:
            return
        }
        phase = .saving
        updateStatus()
        ticker?.invalidate()
        do {
            let project = try await recorder!.stop()
            recorder = nil
            phase = .idle
            removeStatusItem()
            projects = ProjectFolder.all()
            NSApp.unhide(nil)
            NSApp.activate()
            openEditor?(project.url)
        } catch {
            recorder = nil
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        phase = .idle
        removeStatusItem()
        NSApp.unhide(nil)
        NSApp.activate()
        let msg = error.localizedDescription
        if (error as NSError).domain == SCStreamErrorDomain || msg.localizedCaseInsensitiveContains("declined") {
            needsPermission = true
        }
        problem = msg
    }

    func delete(_ p: ProjectFolder) {
        try? FileManager.default.trashItem(at: p.url, resultingItemURL: nil)
        projects = ProjectFolder.all()
    }

    // MARK: Menu bar control

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        statusItem = item
    }

    private func removeStatusItem() {
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil
    }

    @objc private func statusClicked() {
        Task { await stopRecording() }
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let text: String
        switch phase {
        case .countdown(let n): text = "Recording in \(n)…  (click to cancel)"
        case .recording:
            let s = Int(Date().timeIntervalSince(started))
            text = String(format: "%d:%02d  Stop", s / 60, s % 60)
        case .saving: text = "Saving…"
        case .idle: text = ""
        }
        let dot = NSAttributedString(string: "● ", attributes: [.foregroundColor: phase == .recording ? NSColor.systemRed : NSColor.secondaryLabelColor])
        let s = NSMutableAttributedString(attributedString: dot)
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]))
        button.attributedTitle = s
    }
}

/// Answers closeup://record, closeup://stop and closeup://open?path=/path/to/Recording.closeup.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState? {
        didSet { if let url = pending { pending = nil; handle(url) } }
    }
    private var pending: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(getURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func getURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if app?.openEditor == nil { pending = url } else { handle(url) }
    }

    private func handle(_ url: URL) {
        switch url.host {
        case "record":
            // closeup://record?camera=1&mic=1 — flags override the toggles for this take.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let c = q.first(where: { $0.name == "camera" })?.value { app?.camera = c == "1" }
            if let m = q.first(where: { $0.name == "mic" })?.value { app?.microphone = m == "1" }
            app?.refresh()
            app?.startRecording()
            return
        case "stop": Task { await app?.stopRecording() }; return
        default: break
        }
        guard url.host == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
        else { return }
        app?.openEditor?(URL(fileURLWithPath: path, isDirectory: true))
        NSApp.activate()
    }
}
