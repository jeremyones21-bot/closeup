import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Everything besides the style that changes what a frame looks like, keyed to recording time.
struct SceneData: @unchecked Sendable {
    var crop: CGRect?
    var masks: [Span] = []
    var layouts: [Span] = []
    var captions: [Caption] = []
    var shortcuts: [ShortcutPress] = []
    var faces: [FaceSample] = []
    var silences: [Span] = []
}

struct FaceSample: Codable, Equatable { var t: Double; var x: Double; var y: Double; var size: Double }

/// One caption line, with each word's timing for word-by-word styles.
struct Caption: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var words: [Word]
    var text: String { words.map(\.text).joined(separator: " ") }

    struct Word: Codable, Equatable { var start: Double; var end: Double; var text: String }
}

/// Turns one recorded frame into one finished frame:
/// backdrop → shadow → screen (cropped, masked) → cursor → camera move → loupe →
/// webcam (in its layout) → captions and shortcuts.
/// Used by the live preview and by export through a custom AVVideoCompositing, so what you see is
/// what you get.
final class Compositor: @unchecked Sendable {
    let context: CIContext

    private let lock = NSLock()
    private var style: Style
    private var motion: Motion
    private var scene = SceneData()
    private let displayPoints: CGSize      // the recorded display, in points
    private var backdropCache: (key: String, image: CIImage)?
    private var wallpaper: (path: String, image: CIImage)?
    private var device: String?
    private var hasCursor = true
    private var superResolution: Prefs.SuperResolution = .off
    private var textCache: [String: CIImage] = [:]

    private let arrow: (image: CIImage, hotspot: CGPoint, pointHeight: Double)
    private let dot: CIImage
    private let ring: CIImage
    private let clickRing: CIImage

    init(style: Style, motion: Motion, displayPoints: CGSize) {
        self.style = style
        self.motion = motion
        self.displayPoints = displayPoints
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
        arrow = Compositor.arrowCursor()
        dot = Compositor.circleImage(fill: .black, stroke: .white, strokeWidth: 0.16)
        ring = Compositor.circleImage(fill: nil, stroke: .white, strokeWidth: 0.08)
        clickRing = Compositor.clickRingImage()
    }

    func update(style: Style, motion: Motion, scene: SceneData? = nil) {
        lock.lock()
        self.style = style
        self.motion = motion
        if let scene { self.scene = scene }
        lock.unlock()
        loadBackdropImageIfNeeded(style)
    }

    func setDevice(_ name: String?, hasCursor: Bool) {
        lock.lock()
        device = name
        self.hasCursor = hasCursor
        backdropCache = nil
        lock.unlock()
    }

    var wantsCutout: Bool { lock.withLock { style.cameraCutout && style.showCamera } }

    func setSuperResolution(_ s: Prefs.SuperResolution) {
        lock.lock(); superResolution = s; lock.unlock()
    }

    private var isPad: Bool { device?.localizedCaseInsensitiveContains("ipad") ?? false }

    /// Device screens have their own, much rounder corners.
    private func screenRadius(_ style: Style, screen: CGRect, short: Double, device: String?) -> Double {
        guard device != nil else { return style.corner * short }
        return screen.width * (isPad ? 0.035 : 0.12)
    }

    /// Output size for a recording of `source` pixels, with `short` pixels on the short side.
    func canvas(source: CGSize, short: Double) -> CGSize {
        lock.lock(); let aspect = style.aspect; let crop = scene.crop; lock.unlock()
        let src = crop.map { CGSize(width: source.width * $0.width, height: source.height * $0.height) } ?? source
        let r = aspect.ratio ?? (src.width / max(src.height, 1))
        let w = r >= 1 ? short * r : short
        let h = r >= 1 ? short : short / r
        return CGSize(width: Double(Int(w.rounded()) & ~1), height: Double(Int(h.rounded()) & ~1))
    }

    // MARK: Layout

    /// Where the screen and the camera go for a layout, before any animation.
    private struct Placement {
        var screenArea: CGRect      // area the screen is fitted into (before padding)
        var screenAlpha: Double
        var camera: CGRect?         // nil = no camera
        var cameraRadius: Double
    }

    private func placement(_ layout: CameraLayout, style: Style, canvas: CGSize, hasCamera: Bool) -> Placement {
        let full = CGRect(origin: .zero, size: canvas)
        let short = min(canvas.width, canvas.height)
        guard hasCamera, style.showCamera else { return Placement(screenArea: full, screenAlpha: 1, camera: nil, cameraRadius: 0) }
        switch layout {
        case .overlay:
            let d = style.cameraSize * short
            let m = 0.045 * short
            let left = style.cameraCorner == .bottomLeft || style.cameraCorner == .topLeft
            let bottom = style.cameraCorner == .bottomLeft || style.cameraCorner == .bottomRight
            let r = CGRect(x: left ? m : canvas.width - m - d, y: bottom ? m : canvas.height - m - d, width: d, height: d)
            return Placement(screenArea: full, screenAlpha: 1, camera: r,
                             cameraRadius: style.cameraShape == .circle ? d / 2 : d * 0.18)
        case .fullscreen:
            return Placement(screenArea: full.insetBy(dx: canvas.width * 0.3, dy: canvas.height * 0.3), screenAlpha: 0,
                             camera: full, cameraRadius: 0)
        case .split:
            let gap = 0.03 * short
            if canvas.width >= canvas.height {
                let camW = canvas.width * 0.36
                let cam = CGRect(x: canvas.width - camW - gap, y: gap * 2, width: camW, height: canvas.height - gap * 4)
                return Placement(screenArea: CGRect(x: 0, y: 0, width: canvas.width - camW - gap, height: canvas.height),
                                 screenAlpha: 1, camera: cam, cameraRadius: style.corner * short * 1.5)
            } else {
                let camH = canvas.height * 0.36
                let cam = CGRect(x: gap * 2, y: gap, width: canvas.width - gap * 4, height: camH)
                return Placement(screenArea: CGRect(x: 0, y: camH + gap, width: canvas.width, height: canvas.height - camH - gap),
                                 screenAlpha: 1, camera: cam, cameraRadius: style.corner * short * 1.5)
            }
        case .screenOnly:
            return Placement(screenArea: full, screenAlpha: 1, camera: nil, cameraRadius: 0)
        }
    }

    /// Current placement, animating over 0.45 s when the layout changes.
    private func currentPlacement(t: Double, style: Style, scene: SceneData, canvas: CGSize, hasCamera: Bool) -> Placement {
        let spans = scene.layouts.sorted { $0.start < $1.start }
        let now = spans.last { t >= $0.start && t < $0.end }
        let layout = now?.layout ?? .overlay
        // The layout we're coming from: the one in effect just before the current boundary.
        let boundary = now?.start ?? (spans.last { $0.end <= t }?.end ?? -10)
        let previous = spans.last { boundary - 0.001 >= $0.start && boundary - 0.001 < $0.end }?.layout ?? .overlay
        let to = placement(layout, style: style, canvas: canvas, hasCamera: hasCamera)
        let u = min(1, max(0, (t - boundary) / 0.45))
        guard u < 1, previous != layout else { return to }
        let from = placement(previous, style: style, canvas: canvas, hasCamera: hasCamera)
        let e = u * u * (3 - 2 * u)
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * e, y: a.minY + (b.minY - a.minY) * e,
                   width: a.width + (b.width - a.width) * e, height: a.height + (b.height - a.height) * e)
        }
        // A camera appearing or leaving grows from / shrinks to its corner.
        let cornerStub = { (r: CGRect) in CGRect(x: r.midX, y: r.midY, width: 0, height: 0) }
        let fromCam = from.camera ?? to.camera.map(cornerStub)
        let toCam = to.camera ?? from.camera.map(cornerStub)
        return Placement(screenArea: mix(from.screenArea, to.screenArea),
                         screenAlpha: from.screenAlpha + (to.screenAlpha - from.screenAlpha) * e,
                         camera: fromCam.flatMap { a in toCam.map { mix(a, $0) } },
                         cameraRadius: from.cameraRadius + (to.cameraRadius - from.cameraRadius) * e)
    }

    static func screenRect(source: CGSize, in area: CGRect, padding: Double, short: Double) -> CGRect {
        let pad = padding * short
        let aw = max(1, area.width - 2 * pad), ah = max(1, area.height - 2 * pad)
        let s = min(aw / source.width, ah / source.height)
        let w = source.width * s, h = source.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    static func screenRect(source: CGSize, canvas: CGSize, padding: Double) -> CGRect {
        screenRect(source: source, in: CGRect(origin: .zero, size: canvas), padding: padding, short: min(canvas.width, canvas.height))
    }

    /// Recording point (0–1, top-left) → canvas point, before the camera move.
    static func toCanvas(_ x: Double, _ y: Double, screen: CGRect) -> CGPoint {
        CGPoint(x: screen.minX + x * screen.width, y: screen.maxY - y * screen.height)
    }

    /// The camera move at time t: what part of the canvas is shown. Exposed so the editor can
    /// map clicks on the preview back to the recording.
    struct View { var screen: CGRect; var origin: CGPoint; var zoom: Double }

    func view(at t: Double, source: CGSize, canvas: CGSize) -> View {
        lock.lock()
        let style = self.style, motion = self.motion, scene = self.scene, device = self.device
        lock.unlock()
        let src = scene.crop.map { CGSize(width: source.width * $0.width, height: source.height * $0.height) } ?? source
        let short = min(canvas.width, canvas.height)
        let pl = currentPlacement(t: t, style: style, scene: scene, canvas: canvas, hasCamera: false)
        let padding = device == nil ? style.padding : max(style.padding, 0.08)
        let screen = Compositor.screenRect(source: src, in: pl.screenArea, padding: padding + style.inset, short: short)
        let f = motion.frame(at: t)
        let (o, z) = camera(f, screen: screen, canvas: canvas, scene: scene, style: style, cameraRect: nil)
        return View(screen: screen, origin: o, zoom: z)
    }

    private func camera(_ f: Motion.Frame, screen: CGRect, canvas: CGSize, scene: SceneData, style: Style, cameraRect: CGRect?) -> (CGPoint, Double) {
        let z = max(1, f.zoom)
        guard z > 1.001 else { return (.zero, 1) }
        let W = canvas.width, H = canvas.height
        let (fx, fy) = mapIntoCrop(f.focusX, f.focusY, scene.crop)
        let focus = Compositor.toCanvas(fx, fy, screen: screen)
        let vw = W / z, vh = H / z
        var ox = min(max(focus.x - vw / 2, 0), W - vw)
        var oy = min(max(focus.y - vh / 2, 0), H - vh)
        // Smart framing: never let the webcam bubble sit on top of the cursor.
        if let cam = cameraRect {
            let (cx, cy) = mapIntoCrop(f.cursorX, f.cursorY, scene.crop)
            let c = Compositor.toCanvas(cx, cy, screen: screen)
            let onScreen = CGPoint(x: (c.x - ox) * z, y: (c.y - oy) * z)
            let guardRect = cam.insetBy(dx: -0.03 * min(W, H), dy: -0.03 * min(W, H))
            if guardRect.contains(onScreen) {
                // Push the view so the cursor clears the bubble on the side away from it.
                let dx = cam.midX < W / 2 ? (guardRect.maxX - onScreen.x) / z : -(onScreen.x - guardRect.minX) / z
                let dy = cam.midY < H / 2 ? (guardRect.maxY - onScreen.y) / z : -(onScreen.y - guardRect.minY) / z
                if abs(dx) < abs(dy) { ox = min(max(ox - dx, 0), W - vw) } else { oy = min(max(oy - dy, 0), H - vh) }
            }
        }
        return (CGPoint(x: ox, y: oy), z)
    }

    private func mapIntoCrop(_ x: Double, _ y: Double, _ crop: CGRect?) -> (Double, Double) {
        guard let c = crop, c.width > 0, c.height > 0 else { return (x, y) }
        return ((x - c.minX) / c.width, (y - c.minY) / c.height)
    }

    // MARK: Compose

    func compose(source raw: CIImage, camera rawCamera: CIImage? = nil, cameraMask: CIImage? = nil, time: Double, canvas: CGSize) -> CIImage {
        lock.lock()
        let style = self.style, motion = self.motion, scene = self.scene, device = self.device, hasCursor = self.hasCursor
        let superRes = self.superResolution
        lock.unlock()

        let W = canvas.width, H = canvas.height, short = min(W, H)
        let bounds = CGRect(origin: .zero, size: canvas)

        // Crop the recording first; everything after works on what's left.
        var source = raw
        if let c = scene.crop {
            let e = raw.extent
            let r = CGRect(x: e.minX + c.minX * e.width, y: e.minY + (1 - c.maxY) * e.height, width: c.width * e.width, height: c.height * e.height)
            source = raw.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        let src = source.extent

        let f = motion.frame(at: time)
        let pl = currentPlacement(t: time, style: style, scene: scene, canvas: canvas, hasCamera: rawCamera != nil)
        let padding = device == nil ? style.padding : max(style.padding, 0.08)
        let insetPx = style.inset * short
        let frameRect = Compositor.screenRect(source: src.size, in: pl.screenArea, padding: padding, short: short)
        let screen = frameRect.insetBy(dx: insetPx, dy: insetPx * frameRect.height / max(frameRect.width, 1))
        let s = screen.width / src.width

        // Backdrop + shadow + inset frame never change between frames, so render them once.
        let base = backdrop(style: style, canvas: canvas, frame: frameRect, screen: screen, device: device)
        var image = base

        // The recording, scaled into place with rounded corners.
        var placed: CIImage
        let zooming = f.zoom > 1.1 || f.loupe > 0.05
        if superRes != .off, zooming {
            placed = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            if superRes == .quality { placed = placed.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35]) }
            placed = placed.transformed(by: CGAffineTransform(translationX: screen.minX - placed.extent.minX, y: screen.minY - placed.extent.minY))
        } else {
            placed = source.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: screen.minX, y: screen.minY)))
        }
        placed = applyMasks(placed, t: time, screen: screen, scene: scene, short: short)

        let radius = max(0, screenRadius(style, screen: frameRect, short: short, device: device) - insetPx)
        var screenLayer: CIImage
        if radius > 0.5 {
            let mask = Compositor.roundedRect(screen, radius: radius, color: .white)
            screenLayer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
        } else {
            screenLayer = placed.cropped(to: screen)
        }
        if pl.screenAlpha < 0.999 {
            screenLayer = screenLayer.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: pl.screenAlpha)])
        }
        image = screenLayer.composited(over: image)

        // Highlights dim everything but their rectangle.
        for m in scene.masks where m.kind == .highlight && time >= m.start && time < m.end {
            guard let r = m.rect else { continue }
            let hole = rect(r, in: screen)
            let dimmed = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
            let holeMask = Compositor.roundedRect(hole, radius: 0.008 * short, color: .white)
            image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: holeMask])
        }

        // Click ripples and cursor, in screen space so they zoom with everything else.
        let (cx, cy) = mapIntoCrop(f.cursorX, f.cursorY, scene.crop)
        let cpos = Compositor.toCanvas(cx, cy, screen: screen)
        let pointsToCanvas = screen.height / (displayPoints.height * (scene.crop?.height ?? 1))
        if hasCursor, style.clickRipple {
            // A quiet ring that pops out from under the cursor tip and fades: fast ease-out growth,
            // fading as it goes. Dark core with a light rim so it reads on light and dark UI alike.
            let duration = 0.45
            for (age, rx, ry) in f.ripples where age < duration {
                let (mx, my) = mapIntoCrop(rx, ry, scene.crop)
                let p = Compositor.toCanvas(mx, my, screen: screen)
                let u = age / duration
                let grow = 1 - pow(1 - u, 3)
                let size = style.cursorScale / 1.6
                let d = (8 + 26 * grow) * size * pointsToCanvas
                let alpha = 0.7 * pow(1 - u, 1.6)
                let k = d / clickRing.extent.width
                let r = clickRing.transformed(by: CGAffineTransform(translationX: -clickRing.extent.width / 2, y: -clickRing.extent.height / 2)
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                image = r.composited(over: image)
            }
        }
        if hasCursor, f.cursorAlpha > 0.01 {
            var cursor = cursorImage(style: style, press: f.press, pointsToCanvas: pointsToCanvas, at: cpos)
            if style.motionBlur {
                let vx = f.cursorVX * screen.width / 60, vy = -f.cursorVY * screen.height / 60   // px per frame
                let speed = hypot(vx, vy)
                if speed > 2 {
                    cursor = cursor.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: min(24, speed * 0.6), kCIInputAngleKey: atan2(vy, vx),
                    ]).cropped(to: cursor.extent.insetBy(dx: -30, dy: -30))
                }
            }
            if f.cursorAlpha < 0.99 {
                cursor = cursor.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: f.cursorAlpha)])
            }
            image = cursor.composited(over: image)
        }

        // Loupe: a round magnifier over the cursor (or the zoom's point).
        if f.loupe > 0.01 {
            let (lx, ly) = mapIntoCrop(f.focusX == 0.5 && f.focusY == 0.5 ? f.cursorX : f.focusX,
                                       f.focusX == 0.5 && f.focusY == 0.5 ? f.cursorY : f.focusY, scene.crop)
            let c = Compositor.toCanvas(lx, ly, screen: screen)
            let r = 0.17 * short * f.loupe
            let m = f.loupeScale
            let magnified = image.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: m, y: m))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let lens = magnified.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: Compositor.roundedRect(circle, radius: r, color: .white),
            ])
            let shadow = Compositor.roundedRect(circle, radius: r, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .applyingGaussianBlur(sigma: r * 0.08).transformed(by: CGAffineTransform(translationX: 0, y: -r * 0.05))
            let rim = Compositor.roundedRect(circle.insetBy(dx: -max(2, r * 0.025), dy: -max(2, r * 0.025)),
                                             radius: r + max(2, r * 0.025), color: .white)
            image = lens.composited(over: rim.composited(over: shadow.composited(over: image)))
        }

        // Camera move.
        let (o, z) = camera(f, screen: screen, canvas: canvas, scene: scene, style: style, cameraRect: pl.camera)
        if z > 1.001 {
            image = image.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y)
                .concatenating(CGAffineTransform(scaleX: z, y: z)))
            if style.motionBlur {
                // Blur along fast pans and zooms, like a real camera's shutter.
                let pan = hypot(f.focusVX * screen.width, f.focusVY * screen.height) * z / 60
                if abs(f.zoomV) > 1.0 {
                    let focus = Compositor.toCanvas(mapIntoCrop(f.focusX, f.focusY, scene.crop).0, mapIntoCrop(f.focusX, f.focusY, scene.crop).1, screen: screen)
                    image = image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                        kCIInputCenterKey: CIVector(x: (focus.x - o.x) * z, y: (focus.y - o.y) * z),
                        kCIInputAmountKey: min(1.6, (abs(f.zoomV) - 1.0) * 1.2),
                    ])
                } else if pan > 8 {
                    image = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: min(4, (pan - 8) * 0.15), kCIInputAngleKey: atan2(-f.focusVY * screen.height, f.focusVX * screen.width),
                    ])
                }
            }
        }
        image = image.cropped(to: bounds)

        // Webcam, on top of the camera move.
        if let cam = rawCamera, let rect = pl.camera, rect.width > 2 {
            var alpha = 1.0
            if style.hideCameraInSilence { alpha = silenceAlpha(time, scene.silences) }
            if alpha > 0.01 {
                image = cameraLayer(cam, mask: cameraMask, rect: rect, radius: pl.cameraRadius, style: style, scene: scene, t: time, alpha: alpha,
                                    isFull: rect.width >= W - 1).composited(over: image)
            }
        }

        // Captions and keyboard shortcuts, always upright on the final frame.
        if style.captions, let line = scene.captions.first(where: { time >= $0.start && time < $0.end }) {
            image = captionImage(line, t: time, style: style, canvas: canvas).composited(over: image)
        }
        if style.showShortcuts, let k = scene.shortcuts.last(where: { time >= $0.t && time < $0.t + 1.2 }) {
            image = shortcutImage(k.label, age: time - k.t, canvas: canvas).composited(over: image)
        }
        return image.cropped(to: bounds)
    }

    // MARK: Masks

    private func rect(_ r: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + r.minX * screen.width, y: screen.maxY - r.maxY * screen.height,
               width: r.width * screen.width, height: r.height * screen.height)
    }

    private func applyMasks(_ img: CIImage, t: Double, screen: CGRect, scene: SceneData, short: Double) -> CIImage {
        var out = img
        for m in scene.masks where m.kind != .highlight && t >= m.start && t < m.end {
            guard let rr = m.rect else { continue }
            let r = rect(rr, in: screen)
            var patch: CIImage
            switch m.kind {
            case .blur:
                patch = img.clampedToExtent().applyingGaussianBlur(sigma: 0.02 * short)
            case .pixelate:
                patch = img.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: r.minX, y: r.minY), kCIInputScaleKey: max(8, 0.018 * short),
                ])
            case .matched:
                // Fill with the colour just above the box, so it blends into the surrounding UI.
                let strip = CGRect(x: r.minX, y: min(r.maxY + 2, screen.maxY - 3), width: r.width, height: 3)
                patch = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: strip)])
                    .clampedToExtent()
            case .highlight:
                continue
            }
            let shape = Compositor.roundedRect(r, radius: min(r.height, r.width) * 0.12, color: .white)
            out = patch.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: shape])
                .cropped(to: img.extent)
        }
        return out
    }

    // MARK: Cursor

    private func cursorImage(style: Style, press: Double, pointsToCanvas: Double, at p: CGPoint) -> CIImage {
        var scale = style.cursorScale
        if style.clickEffect { scale *= 1 - 0.14 * press }
        switch style.cursorStyle {
        case .arrow:
            let k = arrow.pointHeight * pointsToCanvas * scale / arrow.image.extent.height
            return arrow.image.transformed(by: CGAffineTransform(translationX: -arrow.hotspot.x, y: -arrow.hotspot.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        case .dot, .ring:
            let img = style.cursorStyle == .dot ? dot : ring
            let d = 14 * pointsToCanvas * scale
            let k = d / img.extent.width
            return img.transformed(by: CGAffineTransform(translationX: -img.extent.width / 2, y: -img.extent.height / 2)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        }
    }

    // MARK: Webcam

    private func silenceAlpha(_ t: Double, _ silences: [Span]) -> Double {
        // Fade over 0.3 s at each edge of a silent stretch.
        guard let s = silences.first(where: { t >= $0.start - 0.3 && t < $0.end + 0.3 }) else { return 1 }
        let inFade = min(1, max(0, (t - s.start) / 0.3)), outFade = min(1, max(0, (s.end - t) / 0.3))
        return 1 - min(inFade, outFade)
    }

    private func cameraLayer(_ cam: CIImage, mask: CIImage?, rect: CGRect, radius: Double, style: Style, scene: SceneData,
                             t: Double, alpha: Double, isFull: Bool) -> CIImage {
        var img = cam
        if let mask, style.cameraCutout {
            // Person segmentation: keep the presenter, drop the room.
            let m = mask.transformed(by: CGAffineTransform(scaleX: cam.extent.width / mask.extent.width, y: cam.extent.height / mask.extent.height))
            img = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
        }
        img = applyLook(img, style: style)

        // What part of the camera to show: crop, then centre on the face if tracking.
        let e = cam.extent
        var crop = style.cameraCrop.map { CGRect(x: e.minX + $0.minX * e.width, y: e.minY + (1 - $0.maxY) * e.height,
                                                  width: $0.width * e.width, height: $0.height * e.height) } ?? e
        let aspect = rect.width / max(rect.height, 1)
        var cw = crop.width, ch = cw / aspect
        if ch > crop.height { ch = crop.height; cw = ch * aspect }
        var center = CGPoint(x: crop.midX, y: crop.midY)
        if style.faceTracking, let face = faceAt(t, scene.faces) {
            center = CGPoint(x: e.minX + face.x * e.width, y: e.minY + (1 - face.y) * e.height)
            // Frame the face at about 40% of the shot height, but never zoom past the crop.
            let want = min(ch, max(face.size * e.height / 0.4, ch * 0.5))
            ch = want; cw = want * aspect
        }
        let fx = min(max(center.x - cw / 2, crop.minX), crop.maxX - cw)
        let fy = min(max(center.y - ch / 2, crop.minY), crop.maxY - ch)
        crop = CGRect(x: fx, y: fy, width: cw, height: ch)
        var part = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if style.cameraMirror {
            part = part.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -crop.width, y: 0))
        }
        let k = rect.width / crop.width
        part = part.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))

        var out: CIImage
        if isFull || radius < 0.5 || style.cameraCutout {
            out = part.cropped(to: rect)
        } else {
            out = part.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: Compositor.roundedRect(rect, radius: radius, color: .white),
            ])
            let shadow = Compositor.roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .applyingGaussianBlur(sigma: rect.width * 0.04)
                .transformed(by: CGAffineTransform(translationX: 0, y: -rect.width * 0.02))
            out = out.composited(over: shadow)
        }
        if alpha < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        }
        return out
    }

    private func faceAt(_ t: Double, _ faces: [FaceSample]) -> FaceSample? {
        guard !faces.isEmpty else { return nil }
        guard let j = faces.firstIndex(where: { $0.t >= t }) else { return faces.last }
        guard j > 0 else { return faces[0] }
        let a = faces[j - 1], b = faces[j]
        let u = (t - a.t) / max(b.t - a.t, 0.001)
        return FaceSample(t: t, x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, size: a.size + (b.size - a.size) * u)
    }

    private func applyLook(_ img: CIImage, style: Style) -> CIImage {
        var out = img
        switch style.cameraLook {
        case .natural: break
        case .warm: out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 0)])
        case .cool: out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8200, y: 0)])
        case .vivid: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.08])
        case .mono: out = out.applyingFilter("CIPhotoEffectNoir")
        case .film: out = out.applyingFilter("CIPhotoEffectChrome").applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        }
        if style.cameraSharpen > 0.01 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: style.cameraSharpen])
        }
        return out
    }

    // MARK: Text

    private func textImage(_ key: String, _ draw: () -> NSImage) -> CIImage {
        lock.lock()
        if let c = textCache[key] { lock.unlock(); return c }
        lock.unlock()
        let img = draw()
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return .empty() }
        let ci = CIImage(cgImage: cg)
        lock.lock()
        if textCache.count > 300 { textCache.removeAll() }
        textCache[key] = ci
        lock.unlock()
        return ci
    }

    private static func pill(_ text: NSAttributedString, padX: Double, padY: Double, fill: NSColor?, radius: Double) -> NSImage {
        let size = text.size()
        let w = ceil(size.width + padX * 2), h = ceil(size.height + padY * 2)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            if let fill {
                fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: radius, yRadius: radius).fill()
            }
            text.draw(at: NSPoint(x: padX, y: padY))
            return true
        }
    }

    private func captionImage(_ line: Caption, t: Double, style: Style, canvas: CGSize) -> CIImage {
        let short = min(canvas.width, canvas.height)
        let size = (short * 0.045).rounded()
        let maxWidth = canvas.width * 0.8
        let current = line.words.lastIndex { t >= $0.start } ?? 0
        let key = "cap|\(line.id)|\(style.captionStyle.rawValue)|\(size)|\(style.captionStyle == .karaoke ? current : -1)"
        let img = textImage(key) {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: style.captionStyle == .subtle ? .medium : .bold),
                                                       .paragraphStyle: para]
            let s = NSMutableAttributedString()
            for (i, w) in line.words.enumerated() {
                var a = base
                switch style.captionStyle {
                case .bold, .highlight:
                    a[.foregroundColor] = NSColor.white
                    a[.strokeColor] = NSColor.black
                    a[.strokeWidth] = style.captionStyle == .bold ? -3.0 : 0
                case .subtle:
                    a[.foregroundColor] = NSColor.white.withAlphaComponent(0.92)
                case .karaoke:
                    a[.foregroundColor] = i <= current ? NSColor.white : NSColor.white.withAlphaComponent(0.45)
                    a[.strokeColor] = NSColor.black
                    a[.strokeWidth] = -3.0
                }
                s.append(NSAttributedString(string: (i > 0 ? " " : "") + w.text, attributes: a))
            }
            // Wrap to at most 80% of the frame.
            let bounds = s.boundingRect(with: NSSize(width: maxWidth, height: 1000), options: [.usesLineFragmentOrigin])
            let pad = size * 0.4
            let w = ceil(bounds.width + pad * 2), h = ceil(bounds.height + pad * 1.2)
            let fill: NSColor? = style.captionStyle == .highlight || style.captionStyle == .subtle ? NSColor.black.withAlphaComponent(0.6) : nil
            return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
                if let fill { fill.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: size * 0.3, yRadius: size * 0.3).fill() }
                s.draw(with: NSRect(x: pad, y: pad * 0.6, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin])
                return true
            }
        }
        // Lower third, or above the bottom UI on a vertical video.
        let bottom = canvas.height > canvas.width ? canvas.height * 0.2 : canvas.height * 0.07
        return img.transformed(by: CGAffineTransform(translationX: (canvas.width - img.extent.width) / 2, y: bottom))
    }

    private func shortcutImage(_ label: String, age: Double, canvas: CGSize) -> CIImage {
        let short = min(canvas.width, canvas.height)
        let size = (short * 0.035).rounded()
        let img = textImage("key|\(label)|\(size)") {
            let a = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                                     .foregroundColor: NSColor.white])
            return Compositor.pill(a, padX: size * 0.7, padY: size * 0.35, fill: NSColor(white: 0.08, alpha: 0.85), radius: size * 0.45)
        }
        let fade = age < 0.12 ? age / 0.12 : age > 1.0 ? max(0, (1.2 - age) / 0.2) : 1
        let top = canvas.height > canvas.width ? canvas.height * 0.3 : canvas.height * 0.2
        return img.transformed(by: CGAffineTransform(translationX: (canvas.width - img.extent.width) / 2, y: top))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)])
    }

    // MARK: Backdrop

    private func loadBackdropImageIfNeeded(_ style: Style) {
        let path: String?
        switch style.backdrop {
        case .wallpaper: path = style.imagePath ?? Compositor.currentWallpaperPath()
        case .image: path = style.imagePath
        default: path = nil
        }
        guard let path else { return }
        lock.lock()
        let have = wallpaper?.path == path
        lock.unlock()
        if have { return }
        if let img = CIImage(contentsOf: URL(fileURLWithPath: path)) {
            lock.lock(); wallpaper = (path, img); backdropCache = nil; lock.unlock()
        }
    }

    static func currentWallpaperPath() -> String? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue ? url.path : nil
    }

    /// Built-in macOS wallpapers that are plain image files.
    static func systemWallpapers() -> [URL] {
        let dirs = ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"]
        return dirs.flatMap { d in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func backdrop(style: Style, canvas: CGSize, frame: CGRect, screen: CGRect, device: String?) -> CIImage {
        let key = "\(style.backdrop.rawValue)|\(style.imagePath ?? "")|\(canvas)|\(frame)|\(screen)|\(style.corner)|\(style.shadow)|\(style.shadowAngle)|\(style.shadowDistance)|\(style.shadowSoftness)|\(style.inset)|\(style.insetDark)|\(device ?? "")"
        lock.lock()
        if let c = backdropCache, c.key == key { lock.unlock(); return c.image }
        let wall = (style.backdrop == .wallpaper || style.backdrop == .image) ? wallpaper?.image : nil
        lock.unlock()

        let bounds = CGRect(origin: .zero, size: canvas)
        let short = min(canvas.width, canvas.height)
        var bg: CIImage
        if let wall {
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
            // Debanding: a whisper of noise breaks up the steps an 8-bit gradient would show.
        }
        bg = bg.cropped(to: bounds)

        let radius = screenRadius(style, screen: frame, short: short, device: device)
        if style.shadow > 0.01 {
            let blur = max(1, style.shadowSoftness * short)
            let dist = style.shadowDistance * short
            let angle = style.shadowAngle * .pi / 180
            let shadowRect = device == nil ? frame : frame.insetBy(dx: -frame.width * 0.05, dy: -frame.width * 0.05)
            let shadow = Compositor.roundedRect(shadowRect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * style.shadow))
                .applyingGaussianBlur(sigma: blur / 2)
                .transformed(by: CGAffineTransform(translationX: cos(angle) * dist, y: -sin(angle) * dist))
            bg = shadow.composited(over: bg).cropped(to: bounds)
        }

        // Inset: a frame between the recording and its rounded edge.
        if style.inset > 0.0005, device == nil {
            let c = style.insetDark ? CIColor(red: 0.08, green: 0.08, blue: 0.09) : CIColor(red: 0.97, green: 0.97, blue: 0.97)
            bg = Compositor.roundedRect(frame, radius: radius, color: c).composited(over: bg).cropped(to: bounds)
        }

        // iPhone / iPad: a dark bezel around the screen.
        if device != nil {
            let bezel = frame.width * (isPad ? 0.045 : 0.055)
            let f = frame.insetBy(dx: -bezel, dy: -bezel)
            let r = radius + bezel
            let edge = Compositor.roundedRect(f, radius: r, color: CIColor(red: 0.32, green: 0.33, blue: 0.35))
            let body = Compositor.roundedRect(f.insetBy(dx: bezel * 0.08, dy: bezel * 0.08), radius: r - bezel * 0.08,
                                              color: CIColor(red: 0.05, green: 0.05, blue: 0.06))
            bg = body.composited(over: edge.composited(over: bg)).cropped(to: bounds)
        }

        // Flatten to a bitmap so the blur isn't recomputed every frame.
        var out = bg
        // 16 bits per channel, so a smooth gradient stays smooth without adding noise.
        if let cg = context.createCGImage(bg, from: bounds, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            out = CIImage(cgImage: cg)
        }
        lock.lock()
        backdropCache = (key, out)
        lock.unlock()
        return out
    }

    static func roundedRect(_ r: CGRect, radius: Double, color: CIColor) -> CIImage {
        let g = CIFilter.roundedRectangleGenerator()
        g.extent = r
        g.radius = Float(max(0, min(radius, min(r.width, r.height) / 2)))
        g.color = color
        return g.outputImage!
    }

    /// The click ring: a soft dark band with thin light edges and a faint fill.
    static func clickRingImage() -> CIImage {
        let size = 256.0
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let outer = NSRect(x: 6, y: 6, width: size - 12, height: size - 12)
            NSColor(white: 0.1, alpha: 0.12).setFill()
            NSBezierPath(ovalIn: outer).fill()
            let band = NSBezierPath(ovalIn: outer.insetBy(dx: 10, dy: 10))
            band.lineWidth = 16
            NSColor(white: 1, alpha: 0.9).setStroke()
            band.lineWidth = 30
            band.stroke()
            NSColor(white: 0.12, alpha: 0.8).setStroke()
            band.lineWidth = 20
            band.stroke()
            return true
        }
        var r = CGRect(x: 0, y: 0, width: size, height: size)
        return CIImage(cgImage: img.cgImage(forProposedRect: &r, context: nil, hints: nil)!)
    }

    static func circleImage(fill: NSColor?, stroke: NSColor, strokeWidth: Double) -> CIImage {
        let size = 128.0
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let lw = size * strokeWidth
            let p = NSBezierPath(ovalIn: NSRect(x: lw / 2, y: lw / 2, width: size - lw, height: size - lw))
            if let fill { fill.setFill(); p.fill() }
            stroke.setStroke()
            p.lineWidth = lw
            p.stroke()
            return true
        }
        var r = CGRect(x: 0, y: 0, width: size, height: size)
        return CIImage(cgImage: img.cgImage(forProposedRect: &r, context: nil, hints: nil)!)
    }

    /// The system arrow at its sharpest representation, with its hotspot in CI coordinates.
    static func arrowCursor() -> (image: CIImage, hotspot: CGPoint, pointHeight: Double) {
        let cursor = NSCursor.arrow
        let img = cursor.image
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
        img.draw(in: CGRect(origin: .zero, size: img.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let ci = CIImage(cgImage: rep.cgImage!)
        let hot = cursor.hotSpot  // points, top-left origin
        return (ci, CGPoint(x: hot.x * ctxScale, y: Double(pxH) - hot.y * ctxScale), img.size.height)
    }
}

// MARK: - Video composition + export

enum Render {
    /// The edited recording laid out for playback: screen, audio and camera tracks with trims,
    /// cuts and speed changes applied. Output time maps back to recording time via `timeline`.
    struct Source: @unchecked Sendable {
        let asset: AVAsset
        let screenTrack: CMPersistentTrackID
        let cameraTrack: CMPersistentTrackID?
        let audioTracks: [CMPersistentTrackID]
        let timeline: EditTimeline
        let sourceDuration: Double
        var duration: Double { timeline.duration }
        var musicTrack: CMPersistentTrackID?
        var extraTracks: [CMPersistentTrackID] = []   // clicks and voiceovers, full volume
        var musicVolume: Double = 0.25
        /// Output-time stretches with speech, for ducking the music under the voice.
        var speech: [(Double, Double)] = []

        /// Volumes: the recording's own sound, music (ducked under speech) and the rest.
        func audioMix(volume: Double) -> AVAudioMix? {
            guard let comp = asset as? AVComposition else { return nil }
            let mix = AVMutableAudioMix()
            var params: [AVMutableAudioMixInputParameters] = audioTracks.compactMap { id in
                guard let t = comp.track(withTrackID: id) else { return nil }
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(Float(volume), at: .zero)
                p.audioTimePitchAlgorithm = .spectral   // sped-up speech keeps its pitch
                return p
            }
            if let id = musicTrack, let t = comp.track(withTrackID: id) {
                let p = AVMutableAudioMixInputParameters(track: t)
                let full = Float(musicVolume), ducked = Float(musicVolume * 0.35)
                p.setVolume(speech.isEmpty ? full : full, at: .zero)
                for (a, b) in speech {
                    let r = 0.25
                    p.setVolumeRamp(fromStartVolume: full, toEndVolume: ducked,
                                    timeRange: CMTimeRange(start: CMTime(seconds: max(0, a - r), preferredTimescale: 600), duration: CMTime(seconds: r, preferredTimescale: 600)))
                    p.setVolumeRamp(fromStartVolume: ducked, toEndVolume: full,
                                    timeRange: CMTimeRange(start: CMTime(seconds: b, preferredTimescale: 600), duration: CMTime(seconds: r, preferredTimescale: 600)))
                }
                params.append(p)
            }
            for id in extraTracks {
                if let t = comp.track(withTrackID: id) {
                    let p = AVMutableAudioMixInputParameters(track: t)
                    p.setVolume(1, at: .zero)
                    params.append(p)
                }
            }
            guard !params.isEmpty else { return nil }
            mix.inputParameters = params
            return mix
        }
    }

    static func sourceDuration(_ project: ProjectFolder) async throws -> Double {
        try await AVURLAsset(url: project.video).load(.duration).seconds
    }

    static func source(project: ProjectFolder, cameraOffset: Double?, edits: Edits? = nil) async throws -> Source {
        let screen = AVURLAsset(url: project.video)
        let srcDuration = try await screen.load(.duration).seconds
        let timeline = EditTimeline(edits: edits ?? Edits(), sourceDuration: srcDuration)
        let comp = AVMutableComposition()

        guard let sv = try await screen.loadTracks(withMediaType: .video).first,
              let st = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Closeup", code: 2, userInfo: [NSLocalizedDescriptionKey: "The recording has no video."])
        }
        timeline.insert(sv, trackDuration: srcDuration, into: st)
        var audio: [CMPersistentTrackID] = []
        let e = edits ?? Edits()
        // Cleaned-up voice replaces the first (microphone) track when it's been processed.
        let processed = e.voiceMode.fileName.map { project.url.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? AVURLAsset(url: $0) : nil }
        for (i, a) in try await screen.loadTracks(withMediaType: .audio).enumerated() {
            var track = a
            if i == 0, let processed, let pt = try await processed.loadTracks(withMediaType: .audio).first { track = pt }
            if let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let d = try await track.load(.timeRange).end.seconds
                timeline.insert(track, trackDuration: d, into: at)
                audio.append(at.trackID)
            }
        }
        var extra: [CMPersistentTrackID] = []
        var musicTrack: CMPersistentTrackID?

        // Background music, looped to fill the video.
        if let name = e.musicFile {
            let m = AVURLAsset(url: project.url.appendingPathComponent(name))
            if let mt = try? await m.loadTracks(withMediaType: .audio).first,
               let dest = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let md = (try? await m.load(.duration).seconds) ?? 0
                var at = 0.0
                while md > 0.5, at < timeline.duration {
                    let len = min(md, timeline.duration - at)
                    try? dest.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: len, preferredTimescale: 600)),
                                              of: mt, at: CMTime(seconds: at, preferredTimescale: 600))
                    at += len
                }
                musicTrack = dest.trackID
            }
        }

        // Voiceovers at their recording times.
        for v in e.voiceovers {
            let va = AVURLAsset(url: project.url.appendingPathComponent(v.file))
            guard !timeline.isCut(v.start), let vt = try? await va.loadTracks(withMediaType: .audio).first,
                  let dest = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let vd = (try? await va.load(.duration)) ?? .zero
            try? dest.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: CMTime(seconds: timeline.output(at: v.start), preferredTimescale: 600))
            extra.append(dest.trackID)
        }

        // Click sounds, alternating between two tracks so quick double clicks can overlap.
        if e.style.clickSound, let clickURL = AudioTools.clickSoundURL(),
           let ct = try? await AVURLAsset(url: clickURL).loadTracks(withMediaType: .audio).first {
            let cd = (try? await AVURLAsset(url: clickURL).load(.duration)) ?? CMTime(seconds: 0.05, preferredTimescale: 600)
            let tracks = (0..<2).compactMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
            var wasDown = false
            var n = 0
            for s in project.loadCursor()?.decoded ?? [] {
                defer { wasDown = s.down }
                guard s.down, !wasDown, !timeline.isCut(s.t), tracks.count == 2 else { continue }
                try? tracks[n % 2].insertTimeRange(CMTimeRange(start: .zero, duration: cd), of: ct,
                                                    at: CMTime(seconds: timeline.output(at: s.t), preferredTimescale: 600))
                n += 1
            }
            extra += tracks.filter { !$0.segments.isEmpty }.map(\.trackID)
        }

        var cameraTrack: CMPersistentTrackID?
        if project.hasCamera {
            let cam = AVURLAsset(url: project.cameraVideo)
            if let cv = try await cam.loadTracks(withMediaType: .video).first,
               let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let camDur = try await cam.load(.duration).seconds
                timeline.insert(cv, trackDuration: camDur, offset: cameraOffset ?? 0, into: ct)
                if !ct.segments.isEmpty { cameraTrack = ct.trackID }
            }
        }
        var src = Source(asset: comp, screenTrack: st.trackID, cameraTrack: cameraTrack, audioTracks: audio,
                         timeline: timeline, sourceDuration: srcDuration)
        src.musicTrack = musicTrack
        src.extraTracks = extra
        src.musicVolume = e.musicVolume
        if musicTrack != nil, !audio.isEmpty {
            // Speech = everything that isn't a silence, on the output timeline.
            let silences = await Analyzer.cachedSilences(project)
            var speech: [(Double, Double)] = []
            var cursor = 0.0
            for s in silences.sorted(by: { $0.start < $1.start }) {
                if s.start > cursor { speech.append((cursor, s.start)) }
                cursor = max(cursor, s.end)
            }
            if cursor < srcDuration { speech.append((cursor, srcDuration)) }
            src.speech = speech.map { (timeline.output(at: $0.0), timeline.output(at: $0.1)) }.filter { $0.1 - $0.0 > 0.3 }
        }
        return src
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
            screen: source.screenTrack, camera: source.cameraTrack, compositor: compositor, canvas: canvas,
            timeline: source.timeline)]
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
    let timeline: EditTimeline

    init(timeRange: CMTimeRange, screen: CMPersistentTrackID, camera: CMPersistentTrackID?, compositor: Compositor, canvas: CGSize,
         timeline: EditTimeline) {
        self.timeRange = timeRange
        self.timeline = timeline
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
        let camBuffer = ins.camera.flatMap { request.sourceFrame(byTrackID: $0) }
        let camera = camBuffer.map { CIImage(cvPixelBuffer: $0) }
        var mask: CIImage?
        if let camBuffer, ins.compositor.wantsCutout { mask = Self.personMask(camBuffer) }
        // Zooms, cursor and masks are keyed to recording time, not output time.
        let t = ins.timeline.source(at: request.compositionTime.seconds)
        let image = ins.compositor.compose(source: screen, camera: camera, cameraMask: mask, time: t, canvas: ins.canvas)
        ins.compositor.context.render(image, to: out, bounds: CGRect(origin: .zero, size: ins.canvas), colorSpace: srgb)
        request.finish(withComposedVideoFrame: out)
    }

    /// Vision person segmentation for the camera cutout, run per frame on the GPU / Neural Engine.
    private static func personMask(_ buffer: CVPixelBuffer) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([req])) != nil, let m = req.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: m)
    }
}
