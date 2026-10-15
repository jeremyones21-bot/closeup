import AppKit
import ApplicationServices

/// Sets another app's window to an exact size, so every take of it comes out the same.
/// Needs Accessibility permission (macOS asks the first time).
enum WindowResizer {
    struct Option { let label: String; let size: CGSize }
    static let sizes: [Option] = [
        Option(label: "1280 × 720", size: CGSize(width: 1280, height: 720)),
        Option(label: "1440 × 900", size: CGSize(width: 1440, height: 900)),
        Option(label: "1600 × 900", size: CGSize(width: 1600, height: 900)),
        Option(label: "1920 × 1080", size: CGSize(width: 1920, height: 1080)),
        Option(label: "1080 × 1080", size: CGSize(width: 1080, height: 1080)),
    ]

    enum Result { case done, needsPermission, notFound }

    static func resize(windowID: CGWindowID, to size: CGSize) -> Result {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return .needsPermission }
        guard let info = (CGWindowListCreateDescriptionFromArray([NSNumber(value: windowID)] as CFArray) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return .notFound }

        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return .notFound }

        // Match the AX window to the CG window by frame; titles are often shared.
        func frame(_ w: AXUIElement) -> CGRect? {
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        guard let target = windows.min(by: { a, b in
            let fa = frame(a) ?? .zero, fb = frame(b) ?? .zero
            return abs(fa.minX - bounds.minX) + abs(fa.minY - bounds.minY) + abs(fa.width - bounds.width)
                < abs(fb.minX - bounds.minX) + abs(fb.minY - bounds.minY) + abs(fb.width - bounds.width)
        }) else { return .notFound }

        // Keep it on its screen: if the new size would run off the bottom/right, move it up/left.
        let screen = NSScreen.screens.first { Recorder.cocoaRect(fromCG: bounds).intersects($0.frame) } ?? NSScreen.main
        var origin = bounds.origin
        if let vf = screen.map({ s -> CGRect in
            let f = s.visibleFrame, primary = NSScreen.screens[0].frame.height
            return CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
        }) {
            origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
            origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        }
        var pos = origin, sz = size
        // Position, size, then position again: apps with a minimum size nudge the window when the size lands.
        AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
        usleep(150_000)
        AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
        usleep(150_000)
        AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
        return .done
    }
}
