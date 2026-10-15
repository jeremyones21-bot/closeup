import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via Carbon hot keys, which need no Accessibility permission.
///
///   ⌃⌥⌘R  start / stop recording
///   ⌃⌥⌘P  pause / resume
///   ⌃⌥⌘F  add a flag at this moment
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    struct Combo { let key: Int; let label: String }
    static let startStop = Combo(key: kVK_ANSI_R, label: "⌃⌥⌘R")
    static let pause = Combo(key: kVK_ANSI_P, label: "⌃⌥⌘P")
    static let flag = Combo(key: kVK_ANSI_F, label: "⌃⌥⌘F")

    private var refs: [EventHotKeyRef?] = []
    fileprivate var actions: [UInt32: () -> Void] = [:]

    func install(startStop: @escaping () -> Void, pause: @escaping () -> Void, flag: @escaping () -> Void) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.actions[key]?() } }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(cmdKey | optionKey | controlKey)
        for (i, (combo, action)) in [(Self.startStop, startStop), (Self.pause, pause), (Self.flag, flag)].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434C5550), id: UInt32(i + 1)) // 'CLUP'
            RegisterEventHotKey(UInt32(combo.key), mods, id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
            actions[UInt32(i + 1)] = action
        }
    }
}
