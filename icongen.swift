// Draws the app icon: a framed screen with a zoom bracket around one corner of it.
// Usage: icongen <out.icns>
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).setFill()
    tile.fill()

    // The recorded screen.
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(210, 300, 604, 400), xRadius: 26 * s, yRadius: 26 * s).fill()
    NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(210, 650, 604, 50), xRadius: 0, yRadius: 0).fill()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(210, 660, 604, 40), xRadius: 26 * s, yRadius: 26 * s).fill()
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    for (x, y, w) in [(250.0, 560.0, 220.0), (250.0, 500.0, 300.0), (250.0, 440.0, 180.0)] {
        NSBezierPath(roundedRect: r(x, y, w, 26), xRadius: 13 * s, yRadius: 13 * s).fill()
    }

    // Zoom bracket around the lower-right of the screen.
    NSColor(calibratedRed: 0.20, green: 0.52, blue: 1.0, alpha: 1).setStroke()
    let b = NSBezierPath()
    b.lineWidth = 34 * s
    b.lineCapStyle = .round
    b.lineJoinStyle = .round
    let (x0, y0, x1, y1, k): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (520, 230, 860, 470, 90)
    for (cx, cy, dx, dy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
        b.move(to: NSPoint(x: cx * s, y: (cy + dy * k) * s))
        b.line(to: NSPoint(x: cx * s, y: cy * s))
        b.line(to: NSPoint(x: (cx + dx * k) * s, y: cy * s))
    }
    b.stroke()

    // Cursor inside the bracket.
    let c = NSBezierPath()
    let ox: CGFloat = 640, oy: CGFloat = 410
    c.move(to: NSPoint(x: ox * s, y: oy * s))
    c.line(to: NSPoint(x: ox * s, y: (oy - 130) * s))
    c.line(to: NSPoint(x: (ox + 34) * s, y: (oy - 98) * s))
    c.line(to: NSPoint(x: (ox + 58) * s, y: (oy - 146) * s))
    c.line(to: NSPoint(x: (ox + 78) * s, y: (oy - 136) * s))
    c.line(to: NSPoint(x: (ox + 56) * s, y: (oy - 90) * s))
    c.line(to: NSPoint(x: (ox + 100) * s, y: (oy - 90) * s))
    c.close()
    NSColor.black.setFill()
    c.fill()
    NSColor.white.setStroke()
    c.lineWidth = 12 * s
    c.stroke()
    NSColor.black.setFill()
    c.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Closeup.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
