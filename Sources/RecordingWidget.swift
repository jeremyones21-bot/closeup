import AppKit
import SwiftUI

/// Small floating controls while recording: time, flag, pause, restart, cancel, finish.
/// Closeup's own windows are left out of every capture, so this never appears in the video.
@MainActor
final class RecordingWidget {
    static let shared = RecordingWidget()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil {
            let p = BottomPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.bottomOffset = 24
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: WidgetView().environment(AppState.shared))
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            panel = p
        }
        (panel as? BottomPanel)?.recenter()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
    func toggle() { isVisible ? hide() : show() }
}

private struct WidgetView: View {
    @Environment(AppState.self) private var app
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(app.paused ? Color.secondary : Color.red).frame(width: 8, height: 8)
                Text(app.paused ? "Paused" : app.elapsedText(now))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }
            .padding(.horizontal, 8)
            button("flag", "Add flag (\(Hotkeys.shared.label(.flag)))") { app.addFlag() }.disabled(app.paused)
            button(app.paused ? "play.fill" : "pause.fill", "Pause or resume (\(Hotkeys.shared.label(.pause)))") { app.togglePause() }
            button("arrow.counterclockwise", "Restart (\(Hotkeys.shared.label(.restart)))") { app.restartRecording() }
            button("trash", "Cancel and discard") { app.cancelRecording() }
            Button {
                Task { await app.stopRecording() }
            } label: {
                Text("Finish").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Finish recording (\(Hotkeys.shared.label(.startStop)))")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 0.5)))
        .fixedSize()
        .onReceive(tick) { now = $0 }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Dim what isn't recorded

/// While recording, darkens everything outside the recorded display, window or area, so it's
/// obvious what's in the shot. Clicks pass straight through, and it isn't captured.
@MainActor
final class RegionDimmer {
    static let shared = RegionDimmer()
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var regionProvider: (() -> NSRect?)?

    /// `region` returns the recorded rect in Cocoa global coordinates (re-read for moving windows).
    func show(region: @escaping () -> NSRect?) {
        hide()
        regionProvider = region
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = HoleView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.orderFrontRegardless()
            windows.append(w)
        }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { RegionDimmer.shared.update() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func update() {
        let r = regionProvider?()
        for w in windows {
            guard let v = w.contentView as? HoleView else { continue }
            let local = r.map { NSRect(x: $0.minX - w.frame.minX, y: $0.minY - w.frame.minY, width: $0.width, height: $0.height) }
            if v.hole != local { v.hole = local; v.needsDisplay = true }
        }
    }

    private final class HoleView: NSView {
        var hole: NSRect?
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let h = hole { NSColor.clear.setFill(); h.fill(using: .copy) }
        }
    }
}
