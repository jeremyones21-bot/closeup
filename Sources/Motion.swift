import Foundation

/// Everything that moves, precomputed per frame: the smoothed cursor, the click "press", and the
/// camera (zoom + focus). Rebuilt whenever the segments or smoothing change; it's cheap
/// (a 10-minute take is 36k frames of a few multiplies each).
struct Motion {
    static let fps = 60.0

    let duration: Double
    private var cx: [Float] = [], cy: [Float] = []
    private var press: [Float] = []
    private var idle: [Float] = []
    private var zoom: [Float] = [], fx: [Float] = [], fy: [Float] = []

    struct Frame {
        var cursorX: Double, cursorY: Double   // normalised, top-left origin
        var press: Double                      // 0…1
        var cursorAlpha: Double
        var zoom: Double
        var focusX: Double, focusY: Double     // normalised
    }

    init(samples: [CursorSample], segments: [ZoomSegment], style: Style, duration: Double) {
        self.duration = max(duration, 0.01)
        let n = Int((self.duration * Self.fps).rounded(.up)) + 1
        let dt = 1 / Self.fps
        cx.reserveCapacity(n); cy.reserveCapacity(n); press.reserveCapacity(n)
        idle.reserveCapacity(n); zoom.reserveCapacity(n); fx.reserveCapacity(n); fy.reserveCapacity(n)

        let cursorTime = 0.015 + style.cursorSmoothing * 0.16
        var x = Spring(samples.first?.x ?? 0.5), y = Spring(samples.first?.y ?? 0.5)
        var p = Spring(0)
        var z = Spring(1), fxs = Spring(0.5), fys = Spring(0.5)
        var lastMove = 0.0
        var lastRaw = (samples.first?.x ?? 0.5, samples.first?.y ?? 0.5)
        var idx = 0

        for i in 0..<n {
            let t = Double(i) * dt
            let raw = Self.cursor(at: t, in: samples, hint: &idx)

            if abs(raw.x - lastRaw.0) > 0.0005 || abs(raw.y - lastRaw.1) > 0.0005 || raw.down { lastMove = t }
            lastRaw = (raw.x, raw.y)

            cx.append(Float(x.step(to: raw.x, time: cursorTime, dt: dt)))
            cy.append(Float(y.step(to: raw.y, time: cursorTime, dt: dt)))
            press.append(Float(p.step(to: raw.down ? 1 : 0, time: 0.045, dt: dt)))
            let hidden = style.hideIdleCursor && t - lastMove > 2.5
            idle.append(hidden ? 0 : 1)

            // Camera. Inside a segment, zoom in and drift toward the cursor; outside, sit centred.
            let seg = segments.first { t >= $0.start && t < $0.end }
            let targetZ = seg?.scale ?? 1
            let targetX = seg == nil ? 0.5 : Double(cx[i])
            let targetY = seg == nil ? 0.5 : Double(cy[i])
            zoom.append(Float(z.step(to: targetZ, time: 0.32, dt: dt)))
            fx.append(Float(fxs.step(to: targetX, time: seg == nil ? 0.32 : 0.55, dt: dt)))
            fy.append(Float(fys.step(to: targetY, time: seg == nil ? 0.32 : 0.55, dt: dt)))
        }
        // Fade the cursor rather than popping it when hiding idle cursors.
        if style.hideIdleCursor {
            var a = Spring(1)
            for i in idle.indices { idle[i] = Float(a.step(to: Double(idle[i]), time: 0.12, dt: dt)) }
        }
    }

    func frame(at t: Double) -> Frame {
        let f = max(0, min(Double(cx.count - 1), t * Self.fps))
        let i = Int(f), j = min(i + 1, cx.count - 1)
        let u = Float(f - Double(i))
        func lerp(_ a: [Float]) -> Double { Double(a[i] + (a[j] - a[i]) * u) }
        return Frame(cursorX: lerp(cx), cursorY: lerp(cy), press: lerp(press), cursorAlpha: lerp(idle),
                     zoom: lerp(zoom), focusX: lerp(fx), focusY: lerp(fy))
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
        var segs: [ZoomSegment] = groups.map {
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
        segs = merged
        return segs
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
