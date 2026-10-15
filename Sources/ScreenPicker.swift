import AppKit
import SwiftUI

/// The on-screen picker shown with the recording bar: hover a display (or a window) to see what
/// will be recorded, then press "Start recording". The menu next to it sets what happens after.
@MainActor
final class ScreenPicker {
    static let shared = ScreenPicker()
    private var windows: [NSWindow] = []
    private var mouseMonitor: Any?

    func show(mode: AppState.SourceMode) {
        hide()
        guard mode != .area else { return }
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.acceptsMouseMovedEvents = true
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            w.contentView = NSHostingView(rootView: PickerOverlay(screenFrame: screen.frame, displayID: id, mode: mode)
                .environment(AppState.shared))
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private final class PickerWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

private struct PickerOverlay: View {
    let screenFrame: NSRect
    let displayID: CGDirectDisplayID
    let mode: AppState.SourceMode
    @Environment(AppState.self) private var app
    @State private var hover: AppState.WindowChoice?
    @State private var hoverFrame: CGRect?   // in this view's coordinates (top-left)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(mode == .display && app.displayID == displayID ? 0.18 : 0.35)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if mode == .display { app.displayID = displayID }
                        else if let h = hover { app.windowID = h.id }
                    }

                if mode == .display {
                    card(title: Recorder.screen(for: displayID)?.localizedName ?? "Display",
                         detail: "\(Int(screenFrame.width))×\(Int(screenFrame.height)) · 60 FPS",
                         selected: app.displayID == displayID) {
                        app.displayID = displayID
                        app.startRecording()
                    }
                } else if let f = hoverFrame, let h = hover {
                    Rectangle()
                        .fill(Color.accentColor.opacity(app.windowID == h.id ? 0.16 : 0.08))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: f.width, height: f.height)
                        .position(x: f.midX, y: f.midY)
                        .allowsHitTesting(false)
                    card(title: h.app, detail: h.title.isEmpty ? "\(Int(f.width))×\(Int(f.height))" : h.title,
                         selected: app.windowID == h.id) {
                        app.windowID = h.id
                        app.startRecording()
                    }
                    .position(x: f.midX, y: f.midY)
                } else {
                    Text("Hover a window to record it").font(.title3.weight(.medium)).foregroundStyle(.white)
                }
            }
            .onContinuousHover { phase in
                guard mode == .window, case .active(let p) = phase else { return }
                updateHover(at: p, size: geo.size)
            }
        }
        .ignoresSafeArea()
    }

    /// Front-most normal window under the pointer, excluding Closeup's own.
    private func updateHover(at p: CGPoint, size: CGSize) {
        // View coordinates are top-left within this screen; CG window bounds are top-left global.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
        let screenTopCG = primaryHeight - screenFrame.maxY
        let global = CGPoint(x: screenFrame.minX + p.x, y: screenTopCG + p.y)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let myPID = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != myPID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width > 120, r.height > 80, r.contains(global),
                  let num = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if hover?.id != num {
                hover = app.windows.first { $0.id == num }
                    ?? AppState.WindowChoice(id: num, app: w[kCGWindowOwnerName as String] as? String ?? "Window",
                                             title: w[kCGWindowName as String] as? String ?? "")
            }
            hoverFrame = CGRect(x: r.minX - screenFrame.minX, y: r.minY - screenTopCG, width: r.width, height: r.height)
            return
        }
        hover = nil
        hoverFrame = nil
    }

    private func card(title: String, detail: String, selected: Bool, start: @escaping () -> Void) -> some View {
        @Bindable var prefs = Prefs.shared
        return VStack(spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).monospacedDigit()
            HStack(spacing: 0) {
                Button(action: start) {
                    Label("Start recording", systemImage: "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                }
                .buttonStyle(.plain)
                Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 20)
                Menu {
                    Section("After recording:") {
                        Picker("After recording", selection: $prefs.afterRecording) {
                            ForEach(Prefs.AfterRecording.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Divider()
                    Toggle("Automatically create zooms", isOn: $prefs.autoZooms)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 36)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
        }
        .padding(18)
    }
}
