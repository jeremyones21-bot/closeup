import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns one recorded frame into one finished frame:
/// backdrop → shadow → rounded screen → cursor → camera (zoom + pan).
/// Used both by the live preview and by export, through an AVVideoComposition, so what you
/// see is exactly what you get.
final class Compositor: @unchecked Sendable {
    let context: CIContext

    private let lock = NSLock()
    private var style: Style
    private var motion: Motion
    private let displayPoints: CGSize      // the recorded display, in points
    private var backdropCache: (key: String, image: CIImage)?
    private var wallpaper: CIImage?

    private let cursorImage: CIImage
    private let cursorHotspot: CGPoint       // pixels in cursorImage, CI (bottom-left) origin
    private let cursorPointHeight: Double    // how tall the cursor is on screen, in points

    init(style: Style, motion: Motion, displayPoints: CGSize) {
        self.style = style
        self.motion = motion
        self.displayPoints = displayPoints
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])

        let cursor = Compositor.arrowCursor()
        cursorImage = cursor.image
        cursorHotspot = cursor.hotspot
        cursorPointHeight = cursor.pointHeight
    }

    func update(style: Style, motion: Motion) {
        lock.lock()
        if style.backdrop == .wallpaper, wallpaper == nil { wallpaper = Compositor.loadWallpaper() }
        self.style = style
        self.motion = motion
        lock.unlock()
    }

    /// Output size for a recording of `source` pixels, with `short` pixels on the short side.
    func canvas(source: CGSize, short: Double) -> CGSize {
        lock.lock(); let aspect = style.aspect; lock.unlock()
        let r = aspect.ratio ?? (source.width / max(source.height, 1))
        let w = r >= 1 ? short * r : short
        let h = r >= 1 ? short : short / r
        return CGSize(width: Double(Int(w.rounded()) & ~1), height: Double(Int(h.rounded()) & ~1))
    }

    func compose(source: CIImage, time: Double, canvas: CGSize) -> CIImage {
        lock.lock()
        let style = self.style, motion = self.motion
        lock.unlock()

        let W = canvas.width, H = canvas.height, short = min(W, H)
        let src = source.extent
        let screen = Compositor.screenRect(source: src.size, canvas: canvas, padding: style.padding)
        let s = screen.width / src.width

        // Backdrop + shadow never change between frames, so render them once per look.
        let base = backdrop(style: style, canvas: canvas, screen: screen)

        // The recording, scaled into place with rounded corners.
        let placed = source
            .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: screen.minX, y: screen.minY)))
        var image: CIImage
        let radius = style.corner * short
        if radius > 0.5 {
            let mask = Compositor.roundedRect(screen, radius: radius, color: .white)
            image = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ]).composited(over: base)
        } else {
            image = placed.cropped(to: screen).composited(over: base)
        }

        let f = motion.frame(at: time)

        // Cursor, drawn in screen space so it zooms with everything else.
        if f.cursorAlpha > 0.01 {
            let px = screen.minX + f.cursorX * screen.width
            let py = screen.maxY - f.cursorY * screen.height
            let pointsToCanvas = screen.height / displayPoints.height
            var height = cursorPointHeight * pointsToCanvas * style.cursorScale
            if style.clickEffect { height *= 1 - 0.2 * f.press }
            let k = height / cursorImage.extent.height
            var cursor = cursorImage.transformed(by: CGAffineTransform(translationX: -cursorHotspot.x, y: -cursorHotspot.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: px, y: py)))
            if f.cursorAlpha < 0.99 {
                cursor = cursor.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: f.cursorAlpha),
                ])
            }
            image = cursor.composited(over: image)
        }

        // Camera: show a W/z × H/z window centred on the focus, kept inside the canvas.
        if f.zoom > 1.001 {
            let z = f.zoom
            let focus = CGPoint(x: screen.minX + f.focusX * screen.width, y: screen.maxY - f.focusY * screen.height)
            let vw = W / z, vh = H / z
            let ox = min(max(focus.x - vw / 2, 0), W - vw)
            let oy = min(max(focus.y - vh / 2, 0), H - vh)
            image = image.transformed(by: CGAffineTransform(translationX: -ox, y: -oy)
                .concatenating(CGAffineTransform(scaleX: z, y: z)))
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    static func screenRect(source: CGSize, canvas: CGSize, padding: Double) -> CGRect {
        let pad = padding * min(canvas.width, canvas.height)
        let aw = canvas.width - 2 * pad, ah = canvas.height - 2 * pad
        let s = min(aw / source.width, ah / source.height)
        let w = source.width * s, h = source.height * s
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    // MARK: Pieces

    private func backdrop(style: Style, canvas: CGSize, screen: CGRect) -> CIImage {
        let key = "\(style.backdrop.rawValue)|\(canvas)|\(screen)|\(style.corner)|\(style.shadow)"
        lock.lock()
        if let c = backdropCache, c.key == key { lock.unlock(); return c.image }
        let wall = wallpaper
        lock.unlock()

        let bounds = CGRect(origin: .zero, size: canvas)
        let short = min(canvas.width, canvas.height)
        var bg: CIImage
        if style.backdrop == .wallpaper, let wall {
            let s = max(canvas.width / wall.extent.width, canvas.height / wall.extent.height)
            let scaled = wall.transformed(by: CGAffineTransform(scaleX: s, y: s))
            bg = scaled.transformed(by: CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                          y: (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY))
        } else {
            let (top, bottom) = style.backdrop.colors
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: 0, y: canvas.height)
            g.point1 = CGPoint(x: canvas.width * 0.25, y: 0)
            g.color0 = CIColor(red: top.0, green: top.1, blue: top.2)
            g.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2)
            bg = g.outputImage!
        }
        bg = bg.cropped(to: bounds)

        if style.shadow > 0.01 {
            let blur = 0.03 * short
            let shadow = Compositor.roundedRect(screen, radius: style.corner * short, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * style.shadow))
                .applyingGaussianBlur(sigma: blur / 2)
                .transformed(by: CGAffineTransform(translationX: 0, y: -0.012 * short))
            bg = shadow.composited(over: bg).cropped(to: bounds)
        }

        // Flatten to a bitmap so the blur isn't recomputed every frame.
        var out = bg
        if let cg = context.createCGImage(bg, from: bounds) { out = CIImage(cgImage: cg) }
        lock.lock()
        backdropCache = (key, out)
        lock.unlock()
        return out
    }

    static func roundedRect(_ r: CGRect, radius: Double, color: CIColor) -> CIImage {
        let g = CIFilter.roundedRectangleGenerator()
        g.extent = r
        g.radius = Float(radius)
        g.color = color
        return g.outputImage!
    }

    static func loadWallpaper() -> CIImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            return CIImage(contentsOf: url)
        }
        return nil
    }

    /// The system arrow at its sharpest representation, with its hotspot in CI coordinates.
    static func arrowCursor() -> (image: CIImage, hotspot: CGPoint, pointHeight: Double) {
        let cursor = NSCursor.arrow
        let img = cursor.image
        var rect = CGRect(origin: .zero, size: img.size)
        let best = img.representations.max { $0.pixelsHigh < $1.pixelsHigh }
        let scale = best.map { Double($0.pixelsHigh) / max(img.size.height, 1) } ?? 2
        let ctxScale = max(scale, 4)   // render big; it gets scaled down per frame
        let pxW = Int(img.size.width * ctxScale), pxH = Int(img.size.height * ctxScale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
        let ci = CIImage(cgImage: rep.cgImage!)
        let hot = cursor.hotSpot  // points, top-left origin
        return (ci, CGPoint(x: hot.x * ctxScale, y: Double(pxH) - hot.y * ctxScale), img.size.height)
    }
}

// MARK: - Video composition + export

enum Render {
    static func composition(asset: AVAsset, compositor: Compositor, canvas: CGSize) async throws -> AVVideoComposition {
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let out = compositor.compose(source: request.sourceImage, time: request.compositionTime.seconds, canvas: canvas)
            request.finish(with: out, context: compositor.context)
        }
        comp.renderSize = canvas
        comp.frameDuration = CMTime(value: 1, timescale: 60)
        // Without this, output frames follow the recording's frame times. ScreenCaptureKit only
        // sends frames when the screen changes, so zooms would stutter over still moments.
        comp.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return comp
    }

    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: String { rawValue }
        var label: String { self == .h264 ? "H.264 (most compatible)" : "HEVC (smaller)" }
        var preset: String { self == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality }
    }

    static func export(asset: AVAsset, composition: AVVideoComposition, range: CMTimeRange, codec: Codec,
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: codec.preset) else {
            throw NSError(domain: "Closeup", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Mac can't export with that codec."])
        }
        session.videoComposition = composition
        session.timeRange = range
        try? FileManager.default.removeItem(at: url)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }
}
