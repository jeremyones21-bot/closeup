import Foundation

/// Everything that moves, precomputed per frame of recording time: the smoothed cursor, the click
/// "press", the camera (zoom + focus) and the loupe. Rebuilt when zooms, smoothing or hidden-cursor
/// sections change; it's cheap (a 10-minute take is 36k frames of a few multiplies each).
struct Motion: @unchecked Sendable {
    static let fps = 60.0

    let duration: Double
    private var cx: [Float] = [], cy: [Float] = []
    private var press: [Float] = []
    private var alpha: [Float] = []
    private var zoom: [Float] = [], fx: [Float] = [], fy: [Float] = []
    private var loupe: [Float] = [], loupeScale: [Float] = []
    let clicks: [CursorSample]

    struct Frame {
        var cursorX: Double, cursorY: Double   // normalised, top-left origin
        var press: Double                      // 0…1
        var cursorAlpha: Double
        var zoom: Double
        var focusX: Double, focusY: Double     // normalised
        var loupe: Double                      // 0…1 (how far the loupe is open)
        var loupeScale: Double
        // Per-second rates, for motion blur.
        var cursorVX: Double = 0, cursorVY: Double = 0
        var zoomV: Double = 0, focusVX: Double = 0, focusVY: Double = 0
        /// Clicks in the last half second: (age in seconds, x, y).
        var ripples: [(Double, Double, Double)] = []
    }

    init(samples: [CursorSample], segments: [ZoomSegment], style: Style, duration: Double,
         hidden: [Span] = [], loopEnd: Double? = nil, loopStart: Double = 0) {
        self.duration = max(duration, 0.01)
        let n = Int((self.duration * Self.fps).rounded(.up)) + 1
        let dt = 1 / Self.fps
        var wasDown = false
        var found: [CursorSample] = []
        for s in samples { if s.down && !wasDown { found.append(s) }; wasDown = s.down }
        clicks = found

        let cursorTime = 0.015 + style.cursorSmoothing * 0.16
        var x = Spring(samples.first?.x ?? 0.5), y = Spring(samples.first?.y ?? 0.5)
        var p = Spring(0), a = Spring(1)
        var z = Spring(1), fxs = Spring(0.5), fys = Spring(0.5)
        var lo = Spring(0), ls = Spring(2)
        var lastMove = 0.0
        var lastRaw = (samples.first?.x ?? 0.5, samples.first?.y ?? 0.5)
        var idx = 0
        // Camera aim, held between zooms so zooming out doesn't swing back to the centre.
        var aimX = 0.5, aimY = 0.5
        var aimedAt: UUID?
        let classics = segments.filter { $0.kind == .classic }
        var loopHint = 0
        let home = Self.cursor(at: loopStart, in: samples, hint: &loopHint)

        for i in 0..<n {
            let t = Double(i) * dt
            var raw = Self.cursor(at: t, in: samples, hint: &idx)

            // Loop: glide back to where the cursor was at the start, over the last 0.8 s.
            if style.loopCursor, let end = loopEnd, t > end - 0.8 {
                let u = min(1, (t - (end - 0.8)) / 0.6)
                let e = u * u * (3 - 2 * u)
                raw.x += (home.x - raw.x) * e
                raw.y += (home.y - raw.y) * e
                raw.down = false
            }

            if abs(raw.x - lastRaw.0) > 0.0005 || abs(raw.y - lastRaw.1) > 0.0005 || raw.down { lastMove = t }
            lastRaw = (raw.x, raw.y)

            let sx = style.cursorSmoothing <= 0.001 ? raw.x : x.step(to: raw.x, time: cursorTime, dt: dt)
            let sy = style.cursorSmoothing <= 0.001 ? raw.y : y.step(to: raw.y, time: cursorTime, dt: dt)
            cx.append(Float(sx)); cy.append(Float(sy))
            press.append(Float(p.step(to: raw.down ? 1 : 0, time: 0.045, dt: dt)))
            let idleHidden = style.hideIdleCursor && t - lastMove > 2.5
            let spanHidden = hidden.contains { t >= $0.start && t < $0.end }
            alpha.append(Float(a.step(to: idleHidden || spanHidden ? 0 : 1, time: 0.1, dt: dt)))

            // Camera. A classic zoom eases in over up to 0.9 s and out the same way, ending exactly
            // when the segment does. Inside it, the camera aims where the action will be (the
            // cursor a moment ahead), then only moves when the cursor nears the edge of the view.
            let seg = segments.first { t >= $0.start && t < $0.end }
            let classic = seg?.kind == .classic ? seg : nil
            let level = Self.zoomLevel(at: t, classics)
            zoom.append(Float(level))
            if let c = classic {
                if let f = c.focus {
                    aimX = Double(f.x); aimY = Double(f.y)
                } else {
                    if aimedAt != c.id {
                        aimedAt = c.id
                        var h = 0
                        let ahead = Self.cursor(at: min(c.end, c.start + Self.rampTime(c) + 0.15), in: samples, hint: &h)
                        aimX = ahead.x; aimY = ahead.y
                    }
                    // Dead zone: the cursor can roam the middle of the view without moving the camera.
                    let reach = 0.5 / c.scale * 0.55
                    let dx = sx - aimX, dy = sy - aimY
                    if abs(dx) > reach { aimX += dx - (dx > 0 ? reach : -reach) }
                    if abs(dy) > reach { aimY += dy - (dy > 0 ? reach : -reach) }
                }
            }
            // Fully zoomed out, the aim is invisible: jump it so the next zoom heads straight in.
            if level < 1.01 { fxs = Spring(aimX); fys = Spring(aimY) }
            let follow = classic?.instant == true ? 0.001 : 0.42
            fx.append(Float(fxs.step(to: aimX, time: follow, dt: dt)))
            fy.append(Float(fys.step(to: aimY, time: follow, dt: dt)))
            _ = z
            let fast = seg?.instant == true
            let isLoupe = seg?.kind == .loupe
            loupe.append(Float(lo.step(to: isLoupe ? 1 : 0, time: fast ? 0.001 : 0.18, dt: dt)))
            loupeScale.append(Float(ls.step(to: isLoupe ? (seg?.scale ?? 2) : Double(loupeScale.last ?? 2), time: 0.2, dt: dt)))
        }
    }

    /// How long a zoom takes to ease in (and out): up to 0.9 s, less for short zooms.
    static func rampTime(_ s: ZoomSegment) -> Double {
        s.instant ? 0 : min(0.9, max(0.15, (s.end - s.start) / 2.4))
    }

    /// Zoom amount at t from eased in/out ramps, so every zoom has the same shape and finishes on time.
    static func zoomLevel(at t: Double, _ segs: [ZoomSegment]) -> Double {
        var level = 1.0
        for s in segs where t >= s.start && t < s.end {
            let r = rampTime(s)
            let p = r == 0 ? 1 : min(ease((t - s.start) / r), ease((s.end - t) / r))
            level = max(level, 1 + (s.scale - 1) * p)
        }
        return level
    }

    /// Ease-in-out with a quick, decisive middle (cubic).
    static func ease(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    func frame(at t: Double) -> Frame {
        let f = max(0, min(Double(cx.count - 1), t * Self.fps))
        let i = Int(f), j = min(i + 1, cx.count - 1)
        let u = Float(f - Double(i))
        func lerp(_ a: [Float]) -> Double { Double(a[i] + (a[j] - a[i]) * u) }
        func rate(_ a: [Float]) -> Double { i > 0 ? Double(a[i] - a[i - 1]) * Self.fps : 0 }
        var fr = Frame(cursorX: lerp(cx), cursorY: lerp(cy), press: lerp(press), cursorAlpha: lerp(alpha),
                       zoom: lerp(zoom), focusX: lerp(fx), focusY: lerp(fy), loupe: lerp(loupe), loupeScale: lerp(loupeScale))
        fr.cursorVX = rate(cx); fr.cursorVY = rate(cy)
        fr.zoomV = rate(zoom); fr.focusVX = rate(fx); fr.focusVY = rate(fy)
        fr.ripples = clicks.compactMap { c in
            let age = t - c.t
            guard age >= 0 && age < 0.5 else { return nil }
            // Where the drawn (smoothed) cursor was, so the ring sits under its tip.
            let k = max(0, min(cx.count - 1, Int((c.t * Self.fps).rounded())))
            return (age, Double(cx[k]), Double(cy[k]))
        }
        return fr
    }

    /// Linear interpolation over the raw log. `hint` walks forward with t so the whole pass is O(n).
    static func cursor(at t: Double, in s: [CursorSample], hint: inout Int) -> CursorSample {
        guard !s.isEmpty else { return CursorSample(t: t, x: 0.5, y: 0.5, down: false) }
        if t <= s[0].t { return s[0] }
        if t >= s[s.count - 1].t { return s[s.count - 1] }
        if hint >= s.count - 1 || s[hint].t > t { hint = 0 }
        while hint < s.count - 2 && s[hint + 1].t <= t { hint += 1 }
        let a = s[hint], b = s[hint + 1]
        let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return CursorSample(t: t, x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, down: a.down)
    }

    /// Zooms where the clicking happens. Clicks less than 2.5s apart share one zoom; each zoom
    /// starts a beat before the first click and holds a little after the last.
    static func autoSegments(samples: [CursorSample], duration: Double) -> [ZoomSegment] {
        var clicks: [Double] = []
        var wasDown = false
        for s in samples {
            // Ignore the menu bar (that's where Stop lives) and the last second (the Stop click).
            if s.down && !wasDown && s.y > 0.035 && s.t < duration - 1.0 && s.t > 0.3 { clicks.append(s.t) }
            wasDown = s.down
        }
        var groups: [[Double]] = []
        for c in clicks {
            if let last = groups.last?.last, c - last < 2.5 { groups[groups.count - 1].append(c) }
            else { groups.append([c]) }
        }
        let segs: [ZoomSegment] = groups.map {
            ZoomSegment(start: max(0, $0.first! - 0.7), end: min(duration, $0.last! + 1.8), scale: 2.0)
        }
        // Merge zooms that would only briefly pull out between them.
        var merged: [ZoomSegment] = []
        for s in segs where s.end - s.start > 0.4 {
            if var last = merged.last, s.start - last.end < 1.0 {
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// Stretches of steady typing (3+ keys a second for 2+ seconds), to speed up.
    static func typingSpans(keys: [Double]) -> [Span] {
        var spans: [Span] = []
        var start: Double?
        var last = 0.0, count = 0
        for k in keys.sorted() {
            if let s = start, k - last < 0.6 {
                count += 1
                last = k
                _ = s
            } else {
                if let s = start, last - s >= 2, Double(count) / max(last - s, 0.1) >= 3 {
                    spans.append(Span(start: s, end: last, rate: 3))
                }
                start = k
                last = k
                count = 1
            }
        }
        if let s = start, last - s >= 2, Double(count) / max(last - s, 0.1) >= 3 { spans.append(Span(start: s, end: last, rate: 3)) }
        return spans
    }
}

/// Critically damped spring ("SmoothDamp"): no overshoot, frame-rate independent.
struct Spring {
    var value: Double
    var velocity = 0.0
    init(_ v: Double) { value = v }

    mutating func step(to target: Double, time: Double, dt: Double) -> Double {
        let omega = 2 / max(time, 0.0001)
        let x = omega * dt
        let e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = value - target
        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * e
        value = target + (change + temp) * e
        return value
    }
}
