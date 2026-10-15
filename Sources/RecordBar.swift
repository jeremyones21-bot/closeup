import AppKit
import SwiftUI

/// The floating bar at the bottom of the screen where a recording is set up:
/// what to record, camera, microphone, Mac sound, then Record.
@MainActor
final class RecordBarController {
    private var panel: NSPanel?

    func show(app: AppState) {
        if panel == nil {
            let p = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        guard let panel else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 28, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct RecordBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 4) {
            Button {
                app.bar.hide()
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

            Button {
                app.systemAudio.toggle()
            } label: {
                BarLabel(symbol: app.systemAudio ? "speaker.wave.2" : "speaker.slash",
                         text: app.systemAudio ? "Mac sound on" : "No Mac sound", active: app.systemAudio)
            }
            .buttonStyle(.plain)
            .help("Record sound playing on this Mac")

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
        .help("Record \(mode == .display ? "a whole display" : mode == .window ? "one window" : "part of the screen")")
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
