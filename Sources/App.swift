import AVFoundation
import ScreenCaptureKit
import SwiftUI

@main
struct CloseupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        Window("Closeup", id: "home") {
            HomeView()
                .environment(app)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 640, height: 520)
        // Always come up with the recordings window, even if it was closed when the app quit.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { app.showBar() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(app.phase != .idle)
                Divider()
                Button("Import Video…") {
                    if let p = ProjectShare.importVideo() { app.refresh(); app.openEditor?(p.url) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Open Shared Project…") {
                    if let p = ProjectShare.importShared() { app.refresh(); app.openEditor?(p.url) }
                }
            }
        }

        WindowGroup("Editor", for: URL.self) { $url in
            if let url {
                EditorView(project: ProjectFolder(url: url))
                    .environment(app)
                    .frame(minWidth: 980, minHeight: 620)
                    .onAppear { app.editorsOpen += 1 }
                    .onDisappear { app.editorsOpen -= 1 }
            }
        }
        .defaultSize(width: 1280, height: 820)

        Window("Welcome to Closeup", id: "welcome") {
            WelcomeView().environment(app)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            MenuBarLabel().environment(app)
        }
    }
}

/// Recording state, the take list, and the menu-bar control used while recording.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Phase: Equatable { case idle, countdown(Int), recording, saving }
    enum SourceMode: String, CaseIterable, Identifiable {
        case display, window, area, device
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .display: "display"
            case .window: "macwindow"
            case .area: "rectangle.dashed"
            case .device: "iphone"
            }
        }
    }
    struct WindowChoice: Identifiable, Hashable {
        let id: CGWindowID
        let app: String
        let title: String
        var label: String { title.isEmpty ? app : "\(app) — \(title)" }
    }
    struct Device: Identifiable, Hashable { let id: String; let name: String }

    var phase: Phase = .idle
    var projects: [ProjectFolder] = ProjectFolder.all()
    var problem: String?
    var needsPermission = false

    // Recording choices, remembered between launches.
    var mode: SourceMode = SourceMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    var displays: [SCDisplay] = []
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var windows: [WindowChoice] = []
    var windowID: CGWindowID?
    var area: (display: CGDirectDisplayID, rect: CGRect)?
    var cameras: [Device] = []
    var microphones: [Device] = []
    var cameraID: String? = UserDefaults.standard.string(forKey: "cameraID") {
        didSet { UserDefaults.standard.set(cameraID, forKey: "cameraID") }
    }
    var microphoneID: String? = UserDefaults.standard.string(forKey: "microphoneID") {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    var systemAudio = UserDefaults.standard.bool(forKey: "systemAudio") {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") }
    }
    /// Bundle IDs whose sound is recorded; nil = all apps.
    var audioApps: [String]? = UserDefaults.standard.stringArray(forKey: "audioApps") {
        didSet { UserDefaults.standard.set(audioApps, forKey: "audioApps") }
    }
    var runningApps: [Device] = []   // apps with windows, for the Mac sound menu
    var hideDesktopIcons = UserDefaults.standard.bool(forKey: "hideDesktopIcons") {
        didSet { UserDefaults.standard.set(hideDesktopIcons, forKey: "hideDesktopIcons") }
    }
    var hideDockIcon = UserDefaults.standard.object(forKey: "hideDockIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideDockIcon, forKey: "hideDockIcon") }
    }
    var countdown = UserDefaults.standard.object(forKey: "countdown") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(countdown, forKey: "countdown") }
    }
    var paused = false
    var recovered: [String] = []
    var phones: [Device] = []
    var phoneID: String?
    var editorsOpen = 0 { didSet { updateDockIcon() } }

    /// Set by a view that has the openWindow action (the menu bar icon, which always exists).
    var openEditor: ((URL) -> Void)?
    var openHome: (() -> Void)?
    var openWelcome: (() -> Void)?

    let bar = RecordBarController()
    private var recorder: Recorder?
    private var statusItem: NSStatusItem?
    private var started = Date()
    private var ticker: Timer?

    var canRecord: Bool {
        switch mode {
        case .display: !displays.isEmpty
        case .window: windowID != nil
        case .area: area != nil
        case .device: phoneID != nil
        }
    }

    func elapsedText(_ now: Date) -> String {
        let s = Int(now.timeIntervalSince(started) - pausedSeconds)
        return String(format: "%d:%02d", max(0, s) / 60, max(0, s) % 60)
    }
    private var pausedSeconds = 0.0
    private var pausedAt: Date?

    /// With "Hide Dock icon" on, the icon only shows while an editor is open.
    func updateDockIcon() {
        guard phase == .idle else { return }
        let hide = Prefs.shared.hideDockIconWhenIdle && editorsOpen <= 0
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
    }

    func refresh() {
        recoverInterruptedTakes()
        projects = ProjectFolder.all()
        cameras = CameraRecorder.devices().map { Device(id: $0.uniqueID, name: $0.localizedName) }
        microphones = Recorder.microphones().map { Device(id: $0.uniqueID, name: $0.localizedName) }
        phones = DeviceRecorder.devices().map { Device(id: $0.uniqueID, name: $0.localizedName) }
        if phoneID == nil || !phones.contains(where: { $0.id == phoneID }) { phoneID = phones.first?.id }
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) { cameraID = nil }
        if let id = microphoneID, !microphones.contains(where: { $0.id == id }) { microphoneID = nil }
        Task {
            do {
                let content = try await Recorder.content()
                displays = content.displays
                let me = Bundle.main.bundleIdentifier
                windows = content.windows
                    .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 160 && $0.frame.height >= 100
                        && $0.owningApplication?.bundleIdentifier != me && $0.owningApplication != nil }
                    .map { WindowChoice(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "Window", title: $0.title ?? "") }
                    .sorted { ($0.app, $0.title) < ($1.app, $1.title) }
                var seen = Set<String>()
                runningApps = content.applications
                    .filter { $0.bundleIdentifier != me && !$0.applicationName.isEmpty }
                    .filter { app in content.windows.contains { $0.owningApplication?.bundleIdentifier == app.bundleIdentifier && $0.isOnScreen } }
                    .compactMap { seen.insert($0.bundleIdentifier).inserted ? Device(id: $0.bundleIdentifier, name: $0.applicationName) : nil }
                    .sorted { $0.name < $1.name }
                needsPermission = false
                if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? CGMainDisplayID() }
                if let w = windowID, !windows.contains(where: { $0.id == w }) { windowID = nil }
            } catch {
                needsPermission = true
            }
        }
    }

    func displayName(_ id: CGDirectDisplayID) -> String {
        guard let d = displays.first(where: { $0.displayID == id }) else { return "Display" }
        return "\(Recorder.screen(for: id)?.localizedName ?? "Display") — \(d.width)×\(d.height)"
    }

    func showBar() {
        guard phase == .idle else { return }
        refresh()
        bar.show(app: self)
        ScreenPicker.shared.show(mode: mode)
    }

    func hideBar() {
        bar.hide()
        ScreenPicker.shared.hide()
    }

    /// Called when the bar's mode changes, so the on-screen picker matches.
    func modeChanged() {
        if bar.isVisible { ScreenPicker.shared.show(mode: mode) }
        if mode == .device { refresh() }
    }

    func shortcut(_ a: ShortcutAction) {
        switch a {
        case .startStop:
            switch phase {
            case .idle: bar.isVisible ? startRecording() : showBar()
            case .countdown, .recording: Task { await stopRecording() }
            case .saving: break
            }
        case .pause: togglePause()
        case .restart: restartRecording()
        case .flag: addFlag()
        case .recordDisplay:
            guard phase == .idle else { return }
            mode = .display
            startRecording()
        case .recordWindow:
            guard phase == .idle else { return }
            mode = .window
            showBar()
        case .recordArea:
            guard phase == .idle else { return }
            mode = .area
            selectArea()
        case .notes: SpeakerNotes.shared.toggle()
        case .prompter: SpeakerNotes.shared.togglePrompter()
        case .controls: if phase == .recording { RecordingWidget.shared.toggle() } else if phase == .idle { bar.isVisible ? hideBar() : showBar() }
        }
    }

    func selectArea() {
        let id = area?.display ?? displayID
        hideBar()
        AreaSelector.shared.begin(display: id, initial: area?.display == id ? area?.rect : nil) { [weak self] result in
            guard let self else { return }
            if let result { self.area = result; self.mode = .area }
            self.bar.show(app: self)
        }
    }

    func startRecording() {
        guard phase == .idle else { return }
        problem = nil
        guard canRecord else {
            problem = mode == .window ? "Pick a window to record." : "Select an area to record."
            showBar()
            return
        }
        Task {
            if cameraID != nil, !(await CameraRecorder.requestAccess()) {
                problem = "Closeup can't use the camera. Turn it on in System Settings › Privacy & Security › Camera, or choose No Camera."
                return
            }
            if microphoneID != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                problem = "Closeup can't use the microphone. Turn it on in System Settings › Privacy & Security › Microphone, or choose No Microphone."
                return
            }
            beginCountdown()
        }
    }

    private func beginCountdown() {
        hideBar()
        showStatusItem()
        if hideDockIcon { NSApp.setActivationPolicy(.accessory) }
        NSApp.hide(nil)
        guard countdown > 0 else {
            Task { await beginCapture() }
            return
        }
        phase = .countdown(countdown)
        updateStatus()
        Task {
            for n in stride(from: countdown - 1, through: 1, by: -1) {
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

    func resizeWindow(to size: CGSize) {
        guard let id = windowID else { return }
        switch WindowResizer.resize(windowID: id, to: size) {
        case .done: problem = nil
        case .needsPermission: problem = "To resize windows, allow Closeup in System Settings › Privacy & Security › Accessibility."
        case .notFound: problem = "Couldn't find that window. Choose it again."
        }
    }

    // MARK: During a take

    func togglePause() {
        guard phase == .recording, let recorder else { return }
        if paused {
            recorder.resume()
            if let p = pausedAt { pausedSeconds += Date().timeIntervalSince(p) }
            pausedAt = nil
        } else {
            recorder.pause()
            pausedAt = .now
        }
        paused.toggle()
        updateStatus()
    }

    func addFlag() {
        guard phase == .recording, !paused else { return }
        recorder?.addFlag()
        flagCount += 1
        updateStatus()
    }
    private var flagCount = 0

    /// Start/stop from the global shortcut: starts with the bar's current choices.
    func hotkeyStartStop() {
        switch phase {
        case .idle: startRecording()
        case .countdown, .recording: Task { await stopRecording() }
        case .saving: break
        }
    }

    /// Throws the current take away and starts a fresh one with the same setup.
    func restartRecording() {
        guard phase == .recording else { return }
        Task {
            await stopRecording(openEditor: false, keepUI: true)
            if let p = projects.first { delete(p); lastTrashed = [] }
            phase = .idle
            beginCountdown()
        }
    }

    /// Stops and throws the take away.
    func cancelRecording() {
        Task {
            await stopRecording(openEditor: false)
            if let p = projects.first { delete(p) }
        }
    }

    /// A take whose app quit mid-recording has screen.mov (playable thanks to fragments) and the
    /// autosaved cursor log but no cursor.json. Finish it so it shows up like any other.
    private func recoverInterruptedTakes() {
        guard phase == .idle else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: ProjectFolder.root, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "closeup" {
            let p = ProjectFolder(url: url)
            if fm.fileExists(atPath: p.partialCursorFile.path), !fm.fileExists(atPath: p.cursorFile.path),
               fm.fileExists(atPath: p.video.path) {
                try? fm.moveItem(at: p.partialCursorFile, to: p.cursorFile)
                recovered.append(p.name)
            }
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
        let target: CaptureTarget
        switch mode {
        case .display: target = .display(displayID)
        case .window: target = .window(windowID ?? 0)
        case .area: target = .area(area?.display ?? displayID, area?.rect ?? .zero)
        case .device: target = .device(phoneID ?? "", name: phones.first { $0.id == phoneID }?.name ?? "iPhone")
        }
        do {
            try await rec.start(CaptureOptions(target: target, microphoneID: microphoneID, systemAudio: systemAudio,
                                               audioApps: audioApps, cameraID: cameraID,
                                               hideDesktopIcons: hideDesktopIcons), into: .makeNew())
            if SpeakerNotes.shared.isVisible { SpeakerNotes.shared.show() }
            recorder = rec
            started = .now
            pausedSeconds = 0
            paused = false
            flagCount = 0
            phase = .recording
            if Prefs.shared.showRecordingWidget { RecordingWidget.shared.show() }
            if let cam = rec.cameraSession { CameraPreview.shared.show(session: cam) }
            if Prefs.shared.highlightRecordedArea, !rec.isDevice {
                RegionDimmer.shared.show { [weak rec] in rec?.liveRegion }
            }
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
            updateStatus()
        } catch {
            fail(error)
        }
    }

    func stopRecording(openEditor shouldOpen: Bool = true, keepUI: Bool = false) async {
        RecordingWidget.shared.hide()
        CameraPreview.shared.hide()
        RegionDimmer.shared.hide()
        switch phase {
        case .countdown:
            phase = .idle
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
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
            paused = false
            if keepUI { return }
            phase = .idle
            removeStatusItem()
            projects = ProjectFolder.all()
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            if shouldOpen { finished(project) }
        } catch {
            recorder = nil
            fail(error)
        }
    }

    /// What to do with a finished take: Settings › Recording › After recording.
    private func finished(_ project: ProjectFolder) {
        if Prefs.shared.showQuickExportWidget {
            QuickExportWidget.shared.show(project: project)
            return
        }
        switch Prefs.shared.afterRecording {
        case .openProject:
            NSApp.activate()
            openEditor?(project.url)
        case .exportCopy, .exportSave:
            let copy = Prefs.shared.afterRecording == .exportCopy
            QuickExportWidget.shared.show(project: project, autoStart: copy ? .copy : .save)
        }
    }

    private func fail(_ error: Error) {
        RecordingWidget.shared.hide()
        CameraPreview.shared.hide()
        RegionDimmer.shared.hide()
        phase = .idle
        paused = false
        removeStatusItem()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate()
        let msg = error.localizedDescription
        if (error as NSError).domain == SCStreamErrorDomain || msg.localizedCaseInsensitiveContains("declined") {
            needsPermission = true
        }
        problem = msg
    }

    /// What the last delete moved, so it can be undone: (original location, place in the Trash).
    var lastTrashed: [(from: URL, to: URL)] = []

    static let projectsTrashed = Notification.Name("CloseupProjectsTrashed")

    /// Moves recordings to the Trash (recoverable) and closes any editor showing them.
    func delete(_ list: [ProjectFolder]) {
        var moved: [(URL, URL)] = []
        for p in list {
            var result: NSURL?
            if (try? FileManager.default.trashItem(at: p.url, resultingItemURL: &result)) != nil, let to = result as URL? {
                moved.append((p.url, to))
            }
        }
        guard !moved.isEmpty else { return }
        lastTrashed = moved
        NotificationCenter.default.post(name: Self.projectsTrashed, object: moved.map(\.0))
        projects = ProjectFolder.all()
    }

    func delete(_ p: ProjectFolder) { delete([p]) }

    func undoDelete() {
        for item in lastTrashed {
            try? FileManager.default.moveItem(at: item.to, to: item.from)
        }
        lastTrashed = []
        projects = ProjectFolder.all()
    }

    // MARK: Menu bar control

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        rebuildStatusMenu()
    }

    /// The menu under the timer while recording.
    private func rebuildStatusMenu() {
        let menu = NSMenu()
        switch phase {
        case .countdown:
            menu.addItem(ClosureMenuItem("Cancel") { [weak self] in Task { await self?.stopRecording() } })
        case .recording:
            menu.addItem(ClosureMenuItem("Stop Recording", key: Hotkeys.shared.label(.startStop)) { [weak self] in Task { await self?.stopRecording() } })
            menu.addItem(ClosureMenuItem(paused ? "Resume" : "Pause", key: Hotkeys.shared.label(.pause)) { [weak self] in self?.togglePause() })
            menu.addItem(ClosureMenuItem("Add Flag", key: Hotkeys.shared.label(.flag)) { [weak self] in self?.addFlag() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(SpeakerNotes.shared.isVisible ? "Hide Speaker Notes" : "Show Speaker Notes") {
                SpeakerNotes.shared.toggle()
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Cancel and Discard") { [weak self] in self?.cancelRecording() })
        default:
            break
        }
        statusItem?.menu = menu
    }

    private func removeStatusItem() {
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let text: String
        switch phase {
        case .countdown(let n): text = "Recording in \(n)…"
        case .recording:
            let s = Int(Date().timeIntervalSince(started))
            text = paused ? "Paused" : String(format: "%d:%02d", s / 60, s % 60) + (flagCount > 0 ? "  ⚑\(flagCount)" : "")
        case .saving: text = "Saving…"
        case .idle: text = ""
        }
        rebuildStatusMenu()
        let dot = NSAttributedString(string: "● ", attributes: [.foregroundColor: phase == .recording && !paused ? NSColor.systemRed : NSColor.secondaryLabelColor])
        let s = NSMutableAttributedString(attributedString: dot)
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]))
        button.attributedTitle = s
    }
}

/// Answers closeup://record, closeup://stop, closeup://bar and closeup://open?path=/path/to/Recording.closeup.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppState? { AppState.shared }
    private var pending: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Hotkeys.shared.perform = { AppState.shared.shortcut($0) }
        Hotkeys.shared.reload()
        // URLs can arrive before any window exists; replay once the home window has registered.
        Task {
            for _ in 0..<50 where AppState.shared.openEditor == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let url = pending { pending = nil; handle(url) }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(getURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func getURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        if app?.openEditor == nil && url.host == "open" { pending = url } else { handle(url) }
    }

    private func handle(_ url: URL) {
        switch url.host {
        case "record":
            // closeup://record?camera=1&mic=1&sound=1 — flags override the bar's choices for this take.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let app else { return }
            app.refresh()
            Task {
                try? await Task.sleep(for: .milliseconds(300))   // let the device lists fill in
                if let c = q.first(where: { $0.name == "camera" })?.value { app.cameraID = c == "1" ? (app.cameraID ?? app.cameras.first?.id) : nil }
                if let m = q.first(where: { $0.name == "mic" })?.value { app.microphoneID = m == "1" ? (app.microphoneID ?? app.microphones.first?.id) : nil }
                if let snd = q.first(where: { $0.name == "sound" })?.value { app.systemAudio = snd == "1" }
                if q.contains(where: { $0.name == "display" }) { app.mode = .display }
                app.startRecording()
            }
            return
        case "stop": Task { await app?.stopRecording() }; return
        case "bar": app?.showBar(); return
        default: break
        }
        guard url.host == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
        else { return }
        app?.openEditor?(URL(fileURLWithPath: path, isDirectory: true))
        NSApp.activate()
    }
}

/// An NSMenuItem that runs a closure, so menus can be built without @objc targets.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: key.map { "\(title)    \($0)" } ?? title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
