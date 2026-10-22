import AppKit
import AVFoundation

/// A live view of the camera while recording, so you can see yourself. It's a Closeup window,
/// so like the recording controls it's left out of the capture; drag it anywhere.
@MainActor
final class CameraPreview {
    static let shared = CameraPreview()
    private var panel: NSPanel?

    func show(session: AVCaptureSession) {
        hide()
        let size: CGFloat = 200
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.visibleFrame.maxX - size - 24, y: screen.visibleFrame.minY + 24, width: size, height: size)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size * 0.22
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
