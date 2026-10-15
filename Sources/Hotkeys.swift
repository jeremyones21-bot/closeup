import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A recorded keyboard shortcut. The label is captured at record time rather than
/// derived from the key code later — key codes are positional, so deriving a label
/// means guessing at the keyboard layout.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var modifiers: UInt32
    var label: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if modifiers & UInt32(optionKey)  != 0 { s += "\u{2325}" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "\u{21E7}" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "\u{2318}" }
        return s + label
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Labels for keys that have no printable character of their own.
    static func label(for event: NSEvent) -> String? {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}",
            kVK_Escape: "\u{238B}", kVK_Delete: "\u{232B}", kVK_ForwardDelete: "\u{2326}",
            kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
            kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
            kVK_Home: "\u{2196}", kVK_End: "\u{2198}",
            kVK_PageUp: "\u{21DE}", kVK_PageDown: "\u{21DF}",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let n = named[Int(event.keyCode)] { return n }
        // charactersIgnoringModifiers still folds in Shift, so ⇧1 would record as "!".
        let raw = event.charactersIgnoringModifiers ?? ""
        guard let c = raw.first, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol else {
            return nil
        }
        return String(c).uppercased()
    }
}


/// Everything that can have a global shortcut. Defaults follow Screen Studio's.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case startStop, pause, restart, flag, recordDisplay, recordWindow, recordArea, notes, prompter, controls
    var id: String { rawValue }

    var title: String {
        switch self {
        case .startStop: "Start new recording / Finish recording"
        case .pause: "Resume / Pause recording in progress"
        case .restart: "Restart recording in progress"
        case .flag: "Create recording flag"
        case .recordDisplay: "Record entire display"
        case .recordWindow: "Record single window"
        case .recordArea: "Record area"
        case .notes: "Show speaker notes"
        case .prompter: "Start / Stop prompter in speaker notes"
        case .controls: "Show / Hide recording controls"
        }
    }

    var symbol: String {
        switch self {
        case .startStop: "record.circle"
        case .pause, .prompter: "playpause"
        case .restart: "arrow.counterclockwise"
        case .flag: "flag"
        case .recordDisplay: "display"
        case .recordWindow: "macwindow"
        case .recordArea: "rectangle.dashed"
        case .notes: "list.bullet.rectangle"
        case .controls: "rectangle.dashed.badge.record"
        }
    }

    var defaultCombo: HotKeyCombo {
        let cmdOpt = UInt32(cmdKey | optionKey)
        switch self {
        case .startStop: return HotKeyCombo(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | controlKey), label: "\u{21A9}")
        case .pause: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: cmdOpt, label: "P")
        case .restart: return HotKeyCombo(keyCode: UInt32(kVK_Delete), modifiers: cmdOpt, label: "\u{232B}")
        case .flag: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: cmdOpt | UInt32(controlKey), label: "F")
        case .recordDisplay: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdOpt, label: "3")
        case .recordWindow: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdOpt, label: "4")
        case .recordArea: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdOpt, label: "5")
        case .notes: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_Slash), modifiers: cmdOpt, label: "/")
        case .prompter: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_Period), modifiers: cmdOpt, label: ".")
        case .controls: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_Quote), modifiers: cmdOpt, label: "'")
        }
    }
}

/// System-wide shortcuts via Carbon hot keys, which need no Accessibility permission.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    fileprivate var actions: [UInt32: ShortcutAction] = [:]
    private var handlerInstalled = false
    var perform: ((ShortcutAction) -> Void)?

    /// User's combo for an action; nil if they removed it.
    func combo(for a: ShortcutAction) -> HotKeyCombo? {
        let d = UserDefaults.standard
        if d.bool(forKey: "shortcut.\(a.rawValue).cleared") { return nil }
        if let data = d.data(forKey: "shortcut.\(a.rawValue)"), let c = try? JSONDecoder().decode(HotKeyCombo.self, from: data) { return c }
        return a.defaultCombo
    }

    func set(_ c: HotKeyCombo?, for a: ShortcutAction) {
        let d = UserDefaults.standard
        if let c {
            d.set(try? JSONEncoder().encode(c), forKey: "shortcut.\(a.rawValue)")
            d.set(false, forKey: "shortcut.\(a.rawValue).cleared")
        } else {
            d.removeObject(forKey: "shortcut.\(a.rawValue)")
            d.set(true, forKey: "shortcut.\(a.rawValue).cleared")
        }
        reload()
    }

    func label(_ a: ShortcutAction) -> String { combo(for: a)?.display ?? "" }

    func reload() {
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let key = id.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let a = Hotkeys.shared.actions[key] { Hotkeys.shared.perform?(a) }
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        for (i, a) in ShortcutAction.allCases.enumerated() {
            guard let c = combo(for: a) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434C5550), id: UInt32(i + 1)) // 'CLUP'
            if RegisterEventHotKey(c.keyCode, c.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = a
            }
        }
    }
}

/// SwiftUI wrapper for the recorder field.
struct ShortcutField: NSViewRepresentable {
    let action: ShortcutAction

    func makeNSView(context: Context) -> HotKeyRecorder {
        let v = HotKeyRecorder()
        v.combo = Hotkeys.shared.combo(for: action)
        v.onChange = { Hotkeys.shared.set($0, for: action) }
        return v
    }

    func updateNSView(_ v: HotKeyRecorder, context: Context) {}
}

// MARK: - Recorder

/// A one-line field that records the next key combination pressed into it.
final class HotKeyRecorder: NSView {

    var combo: HotKeyCombo? { didSet { needsDisplay = true } }
    var onChange: ((HotKeyCombo?) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                   : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Press keys\u{2026}"
            color = .secondaryLabelColor
        } else if let combo {
            text = combo.display
            color = .labelColor
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        // A local monitor beats `keyDown`: it also sees combinations the window would
        // otherwise swallow as menu key equivalents, like ⌘W.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.capture(e)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            combo = nil
            onChange?(nil)
            stopRecording()
            return
        }
        let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
        // A bare letter would steal that key from every app on the system.
        guard mods != 0, mods != UInt32(shiftKey),
              let label = HotKeyCombo.label(for: event) else {
            NSSound.beep()
            return
        }
        let new = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods, label: label)
        combo = new
        onChange?(new)
        stopRecording()
    }
}
