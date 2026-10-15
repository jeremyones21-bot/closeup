import AppKit
import SwiftUI

/// The floating bar at the bottom of the screen where a recording is set up:
/// what to record, camera, microphone, Mac sound, then Record.
@MainActor
final class RecordBarController {
    private var panel: NSPanel?

    func show(app: AppState) {
        if panel == nil {
            let p = BottomPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 64),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.bottomOffset = 28
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: RecordBar().environment(app))
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            panel = p
        }
        guard let panel = panel as? BottomPanel else { return }
        panel.recenter()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }
}

/// A floating panel that stays centred at the bottom of the screen the pointer is on, even as
/// SwiftUI resizes it to fit its content (until you drag it somewhere yourself).
final class BottomPanel: NSPanel {
    var bottomOffset: CGFloat = 28
    private var userMoved = false
    private var placing = false

    override var canBecomeKey: Bool { true }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.userMoved == false { self?.recenter() } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.placing == false, self?.isVisible == true { self?.userMoved = true } }
        }
    }

    func recenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var size = frame.size
        if let fit = contentView?.fittingSize, fit.width > 10 { size = fit }
        placing = true
        setFrame(NSRect(x: (v.midX - size.width / 2).rounded(), y: v.minY + bottomOffset, width: size.width, height: size.height), display: true)
        placing = false
    }

    override func orderOut(_ sender: Any?) {
        userMoved = false   // next time it opens, it's centred again
        super.orderOut(sender)
    }
}

struct RecordBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 4) {
            Button {
                app.hideBar()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")

            ForEach(AppState.SourceMode.allCases) { m in
                ModeButton(mode: m, selected: app.mode == m) {
                    app.mode = m
                    app.modeChanged()
                    if m == .area && app.area == nil { app.selectArea() }
                }
            }

            divider

            sourceDetail
                .frame(minWidth: 150, alignment: .leading)

            divider

            Menu {
                Picker("Camera", selection: $app.cameraID) {
                    Text("No Camera").tag(String?.none)
                    ForEach(app.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
            } label: {
                BarLabel(symbol: app.cameraID == nil ? "video.slash" : "video",
                         text: app.cameras.first { $0.id == app.cameraID }?.name ?? "No camera",
                         active: app.cameraID != nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Picker("Microphone", selection: $app.microphoneID) {
                    Text("No Microphone").tag(String?.none)
                    ForEach(app.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
            } label: {
                BarLabel(symbol: app.microphoneID == nil ? "mic.slash" : "mic",
                         text: app.microphones.first { $0.id == app.microphoneID }?.name ?? "No microphone",
                         active: app.microphoneID != nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button { app.systemAudio = false } label: { checkmark("No Mac Sound", !app.systemAudio) }
                Button { app.systemAudio = true; app.audioApps = nil } label: { checkmark("All Apps", app.systemAudio && app.audioApps == nil) }
                if !app.runningApps.isEmpty {
                    Section("Only These Apps") {
                        ForEach(app.runningApps) { a in
                            Button {
                                var set = Set(app.audioApps ?? [])
                                if set.contains(a.id) { set.remove(a.id) } else { set.insert(a.id) }
                                app.audioApps = set.isEmpty ? nil : Array(set).sorted()
                                app.systemAudio = true
                            } label: { checkmark(a.name, app.systemAudio && (app.audioApps ?? []).contains(a.id)) }
                        }
                    }
                }
            } label: {
                BarLabel(symbol: app.systemAudio ? "speaker.wave.2" : "speaker.slash", text: soundLabel, active: app.systemAudio)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Record sound playing on this Mac")

            Menu {
                Picker("Countdown", selection: $app.countdown) {
                    Text("No Countdown").tag(0)
                    Text("3 Seconds").tag(3)
                    Text("5 Seconds").tag(5)
                    Text("10 Seconds").tag(10)
                }
                Divider()
                Toggle("Hide Desktop Icons", isOn: $app.hideDesktopIcons)
                Toggle("Hide Dock Icon While Recording", isOn: $app.hideDockIcon)
                Divider()
                Button(SpeakerNotes.shared.isVisible ? "Hide Speaker Notes" : "Show Speaker Notes") { SpeakerNotes.shared.toggle() }
                if app.mode == .window, app.windowID != nil {
                    Menu("Resize Window") {
                        ForEach(WindowResizer.sizes, id: \.label) { size in
                            Button(size.label) { app.resizeWindow(to: size.size) }
                        }
                    }
                }

            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recording options")

            Button {
                app.hideBar()
                app.openHome?()
            } label: {
                Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 30, height: 32)
            }
            .buttonStyle(.plain)
            .help("Your recordings")

            divider

            Button {
                app.startRecording()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Text("Record").fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(app.canRecord ? Color.red : Color.gray.opacity(0.4)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!app.canRecord)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        )
        .overlay(alignment: .top) {
            if let p = app.problem {
                Text(p)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(y: -30)
            }
        }
        .fixedSize()
    }

    private var soundLabel: String {
        guard app.systemAudio else { return "No Mac sound" }
        guard let ids = app.audioApps else { return "All Mac sound" }
        return ids.count == 1 ? (app.runningApps.first { $0.id == ids[0] }?.name ?? "1 app") : "Sound from \(ids.count) apps"
    }

    private func checkmark(_ title: String, _ on: Bool) -> some View {
        on ? Label(title, systemImage: "checkmark") : Label(title, systemImage: "")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 30).padding(.horizontal, 6)
    }

    @ViewBuilder private var sourceDetail: some View {
        @Bindable var app = app
        switch app.mode {
        case .display:
            Menu {
                Picker("Display", selection: $app.displayID) {
                    ForEach(app.displays, id: \.displayID) { d in Text(app.displayName(d.displayID)).tag(d.displayID) }
                }
                .pickerStyle(.inline)
            } label: {
                BarLabel(symbol: "display", text: Recorder.screen(for: app.displayID)?.localizedName ?? "Display", active: true)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case .window:
            Menu {
                Picker("Window", selection: $app.windowID) {
                    ForEach(app.windows) { w in Text(w.label).tag(Optional(w.id)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh List") { app.refresh() }
            } label: {
                BarLabel(symbol: "macwindow",
                         text: app.windows.first { $0.id == app.windowID }?.app ?? "Choose window…",
                         active: app.windowID != nil)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case .device:
            Menu {
                Picker("Device", selection: $app.phoneID) {
                    ForEach(app.phones) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh List") { app.refresh() }
            } label: {
                BarLabel(symbol: "iphone",
                         text: app.phones.first { $0.id == app.phoneID }?.name ?? "Connect an iPhone or iPad",
                         active: app.phoneID != nil)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Plug in with a cable, unlock it and tap Trust")
        case .area:
            Button {
                app.selectArea()
            } label: {
                BarLabel(symbol: "rectangle.dashed",
                         text: app.area.map { "\(Int($0.rect.width))×\(Int($0.rect.height)) · Adjust" } ?? "Select area…",
                         active: app.area != nil)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ModeButton: View {
    let mode: AppState.SourceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: mode.symbol).font(.system(size: 15))
                Text(mode.label).font(.system(size: 10))
            }
            .frame(width: 58, height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.14) : .clear))
            .foregroundStyle(selected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(mode == .display ? "Record a whole display" : mode == .window ? "Record one window"
              : mode == .area ? "Record part of the screen" : "Record an iPhone or iPad over USB")
    }
}

private struct BarLabel: View {
    let symbol: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(text).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
        }
        .foregroundStyle(active ? .primary : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
    }
}

// MARK: - Area selection

/// Full-screen overlay on one display: drag to draw the area, Return to confirm, Esc to cancel.
@MainActor
final class AreaSelector {
    static let shared = AreaSelector()
    private var window: NSWindow?
    private var done: ((((display: CGDirectDisplayID, rect: CGRect))?) -> Void)?

    func begin(display: CGDirectDisplayID, initial: CGRect?, done: @escaping (((display: CGDirectDisplayID, rect: CGRect))?) -> Void) {
        guard let screen = Recorder.screen(for: display) ?? NSScreen.main else { done(nil); return }
        self.done = done
        let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = AreaView(frame: NSRect(origin: .zero, size: screen.frame.size))
        if let initial {
            // initial is top-left origin; the view is bottom-left.
            view.selection = NSRect(x: initial.minX, y: screen.frame.height - initial.maxY, width: initial.width, height: initial.height)
        }
        view.finish = { [weak self] rect in
            guard let self else { return }
            self.window?.orderOut(nil)
            self.window = nil
            let result = rect.map { r in
                (display: display, rect: CGRect(x: r.minX.rounded(), y: (screen.frame.height - r.maxY).rounded(),
                                                width: r.width.rounded(), height: r.height.rounded()))
            }
            self.done?(result)
            self.done = nil
        }
        w.contentView = view
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class AreaView: NSView {
        var selection: NSRect?
        var finish: ((NSRect?) -> Void)?
        private var anchor: NSPoint?
        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.45).setFill()
            bounds.fill()
            if let s = selection {
                NSColor.clear.setFill()
                s.fill(using: .copy)
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: s.insetBy(dx: -0.5, dy: -0.5))
                border.lineWidth = 1
                border.stroke()
                let label = "\(Int(s.width)) × \(Int(s.height))   Return to use · Esc to cancel"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                            .foregroundColor: NSColor.white]
                let size = (label as NSString).size(withAttributes: attrs)
                let box = NSRect(x: s.minX, y: max(4, s.minY - size.height - 12), width: size.width + 14, height: size.height + 8)
                NSColor.black.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                (label as NSString).draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attrs)
            } else {
                let hint = "Drag to choose the area to record"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
                let size = (hint as NSString).size(withAttributes: attrs)
                (hint as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            }
        }

        override func mouseDown(with e: NSEvent) { anchor = convert(e.locationInWindow, from: nil) }

        override func mouseDragged(with e: NSEvent) {
            guard let a = anchor else { return }
            let p = convert(e.locationInWindow, from: nil)
            selection = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y)).intersection(bounds)
            needsDisplay = true
        }

        override func mouseUp(with e: NSEvent) {
            anchor = nil
            if let s = selection, s.width < 40 || s.height < 40 { selection = nil; needsDisplay = true }
        }

        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 53: close(nil)                      // Esc
            case 36, 76: if let s = selection { close(s) }   // Return / Enter
            default: super.keyDown(with: e)
            }
        }

        private func close(_ r: NSRect?) {
            NSCursor.pop()
            finish?(r)
        }
    }
}
