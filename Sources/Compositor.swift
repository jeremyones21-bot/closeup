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
    private var device: String?              // iPhone / iPad recordings get a device frame
    private var hasCursor = true              // imported videos and device recordings have none

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

    func setDevice(_ name: String?, hasCursor: Bool) {
        lock.lock()
        device = name
        self.hasCursor = hasCursor
        backdropCache = nil
        lock.unlock()
    }

    private var isPad: Bool { device?.localizedCaseInsensitiveContains("ipad") ?? false }

    /// Device screens have their own, much rounder corners.
    private func screenRadius(_ style: Style, screen: CGRect, short: Double) -> Double {
        guard device != nil else { return style.corner * short }
        return screen.width * (isPad ? 0.035 : 0.12)
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

    func compose(source: CIImage, camera: CIImage? = nil, time: Double, canvas: CGSize) -> CIImage {
        lock.lock()
        let style = self.style, motion = self.motion, device = self.device, hasCursor = self.hasCursor
        lock.unlock()

        let W = canvas.width, H = canvas.height, short = min(W, H)
        let src = source.extent
        // A device frame needs room around the screen for its bezel.
        let padding = device == nil ? style.padding : max(style.padding, 0.08)
        let screen = Compositor.screenRect(source: src.size, canvas: canvas, padding: padding)
        let s = screen.width / src.width

        // Backdrop + shadow never change between frames, so render them once per look.
        let base = backdrop(style: style, canvas: canvas, screen: screen)

        // The recording, scaled into place with rounded corners.
        let placed = source
            .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: screen.minX, y: screen.minY)))
        var image: CIImage
        let radius = screenRadius(style, screen: screen, short: short)
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
        if hasCursor, f.cursorAlpha > 0.01 {
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
        image = image.cropped(to: CGRect(origin: .zero, size: canvas))

        // Camera sits on top of the camera move, pinned to its corner.
        if style.showCamera, let camera {
            image = Compositor.cameraBubble(camera, style: style, canvas: canvas).composited(over: image)
        }
        return image
    }

    /// The webcam, filled into a square, mirrored if asked, masked to a circle or rounded
    /// square, with a soft shadow, placed in a corner of the canvas.
    static func cameraBubble(_ cam: CIImage, style: Style, canvas: CGSize) -> CIImage {
        let short = min(canvas.width, canvas.height)
        let d = style.cameraSize * short
        let margin = 0.045 * short
        let e = cam.extent
        let side = min(e.width, e.height)
        var img = cam.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
        if style.cameraMirror {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
        }
        let k = d / side
        let x: Double = (style.cameraCorner == .bottomLeft || style.cameraCorner == .topLeft) ? margin : canvas.width - margin - d
        let y: Double = (style.cameraCorner == .bottomLeft || style.cameraCorner == .bottomRight) ? margin : canvas.height - margin - d
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: x, y: y)))

        let rect = CGRect(x: x, y: y, width: d, height: d)
        let radius = style.cameraShape == .circle ? d / 2 : d * 0.18
        let mask = roundedRect(rect, radius: radius, color: .white)
        let masked = img.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        let shadow = roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .applyingGaussianBlur(sigma: d * 0.04)
            .transformed(by: CGAffineTransform(translationX: 0, y: -d * 0.02))
        return masked.composited(over: shadow)
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
        let key = "\(style.backdrop.rawValue)|\(canvas)|\(screen)|\(style.corner)|\(style.shadow)|\(device ?? "")"
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
            let shadow = Compositor.roundedRect(device == nil ? screen : screen.insetBy(dx: -screen.width * 0.05, dy: -screen.width * 0.05),
                                                radius: screenRadius(style, screen: screen, short: short), color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * style.shadow))
                .applyingGaussianBlur(sigma: blur / 2)
                .transformed(by: CGAffineTransform(translationX: 0, y: -0.012 * short))
            bg = shadow.composited(over: bg).cropped(to: bounds)
        }

        // iPhone / iPad: a dark bezel around the screen, drawn into the static backdrop.
        if device != nil {
            let bezel = screen.width * (isPad ? 0.045 : 0.055)
            let frame = screen.insetBy(dx: -bezel, dy: -bezel)
            let r = screenRadius(style, screen: screen, short: short) + bezel
            let edge = Compositor.roundedRect(frame, radius: r, color: CIColor(red: 0.32, green: 0.33, blue: 0.35))
            let body = Compositor.roundedRect(frame.insetBy(dx: bezel * 0.08, dy: bezel * 0.08), radius: r - bezel * 0.08,
                                              color: CIColor(red: 0.05, green: 0.05, blue: 0.06))
            bg = body.composited(over: edge.composited(over: bg)).cropped(to: bounds)
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
    /// Screen (and camera, if any) laid on one timeline. Composition time == screen.mov time,
    /// which is what the cursor log and zooms are keyed to.
    struct Source {
        let asset: AVAsset
        let screenTrack: CMPersistentTrackID
        let cameraTrack: CMPersistentTrackID?
        let duration: Double
    }

    static func source(project: ProjectFolder, cameraOffset: Double?) async throws -> Source {
        let screen = AVURLAsset(url: project.video)
        let duration = try await screen.load(.duration)
        let comp = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)

        guard let sv = try await screen.loadTracks(withMediaType: .video).first,
              let st = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Closeup", code: 2, userInfo: [NSLocalizedDescriptionKey: "The recording has no video."])
        }
        try st.insertTimeRange(full, of: sv, at: .zero)
        for a in try await screen.loadTracks(withMediaType: .audio) {
            if let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? at.insertTimeRange(full, of: a, at: .zero)
            }
        }

        var cameraTrack: CMPersistentTrackID?
        if project.hasCamera {
            let cam = AVURLAsset(url: project.cameraVideo)
            if let cv = try await cam.loadTracks(withMediaType: .video).first,
               let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let camDur = try await cam.load(.duration)
                let offset = CMTime(seconds: cameraOffset ?? 0, preferredTimescale: 600)
                // A camera that started before the screen loses its head; one that ran past it, its tail.
                let skip = offset < .zero ? CMTimeMultiply(offset, multiplier: -1) : .zero
                let at = offset < .zero ? .zero : offset
                let len = CMTimeMinimum(CMTimeSubtract(camDur, skip), CMTimeSubtract(duration, at))
                if len > .zero {
                    try ct.insertTimeRange(CMTimeRange(start: skip, duration: len), of: cv, at: at)
                    cameraTrack = ct.trackID
                }
            }
        }
        return Source(asset: comp, screenTrack: st.trackID, cameraTrack: cameraTrack, duration: duration.seconds)
    }

    static func composition(source: Source, compositor: Compositor, canvas: CGSize, fps: Int = 60) -> AVVideoComposition {
        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = CloseupVideoCompositor.self
        comp.renderSize = canvas
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Without this, output frames follow the recording's frame times. ScreenCaptureKit only
        // sends frames when the screen changes, so zooms would stutter over still moments.
        comp.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        comp.instructions = [CloseupInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: source.duration, preferredTimescale: 600)),
            screen: source.screenTrack, camera: source.cameraTrack, compositor: compositor, canvas: canvas)]
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

// MARK: - Custom compositor (two video tracks in, one frame out)

final class CloseupInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true   // the camera moves even when no source frame changes
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screen: CMPersistentTrackID
    let camera: CMPersistentTrackID?
    let compositor: Compositor
    let canvas: CGSize

    init(timeRange: CMTimeRange, screen: CMPersistentTrackID, camera: CMPersistentTrackID?, compositor: Compositor, canvas: CGSize) {
        self.timeRange = timeRange
        self.screen = screen
        self.camera = camera
        self.compositor = compositor
        self.canvas = canvas
        requiredSourceTrackIDs = ([screen] + (camera.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class CloseupVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? CloseupInstruction,
              let screenBuffer = request.sourceFrame(byTrackID: ins.screen),
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Closeup", code: 3))
            return
        }
        let screen = CIImage(cvPixelBuffer: screenBuffer)
        let camera = ins.camera.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        let image = ins.compositor.compose(source: screen, camera: camera, time: request.compositionTime.seconds, canvas: ins.canvas)
        ins.compositor.context.render(image, to: out, bounds: CGRect(origin: .zero, size: ins.canvas), colorSpace: srgb)
        request.finish(withComposedVideoFrame: out)
    }
}
