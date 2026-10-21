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
        var lo = Spring(0), ls = Spring(2)
        var lastMove = 0.0
        var lastRaw = (samples.first?.x ?? 0.5, samples.first?.y ?? 0.5)
        var idx = 0
        // Camera aim, held between zooms so zooming out doesn't swing back to the centre.
        var aimX = 0.5, aimY = 0.5
        let groups = Dictionary(uniqueKeysWithValues: segments.filter { $0.kind == .classic && $0.focus == nil }
            .map { ($0.id, Self.activityGroups(samples: samples, in: $0)) })
        var panX = Spring(0.5), panY = Spring(0.5)
        let live = segments.filter { $0.kind == .classic }
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
            press.append(Float(p.step(to: raw.down ? 1 : 0, time: raw.down ? 0.025 : 0.07, dt: dt)))   // snap down, ease back
            let idleHidden = style.hideIdleCursor && t - lastMove > 2.5
            let spanHidden = hidden.contains { t >= $0.start && t < $0.end }
            alpha.append(Float(a.step(to: idleHidden || spanHidden ? 0 : 1, time: 0.1, dt: dt)))

            // Camera, as Screen Studio does it ("follow click groups"). The cursor activity inside a
            // zoom is split into groups that each fit in the zoomed view; the camera aims at
            // the centre of the group happening now, so it holds still while you work in one place
            // and pans once when you move on.
            let seg = segments.first { t >= $0.start && t < $0.end }
            let classic = seg?.kind == .classic ? seg : nil
            let level = Self.zoomLevel(at: t, live)
            zoom.append(Float(level))
            if let c = classic {
                if let f = c.focus {
                    aimX = Double(f.x); aimY = Double(f.y)
                } else if let g = groups[c.id], let now = Self.group(at: t, in: g) {
                    aimX = now.x; aimY = now.y
                }
            }
            // Fully zoomed out, the aim is invisible: jump it so the next zoom heads straight in.
            if level < 1.01 || classic?.instant == true { panX = Spring(aimX); panY = Spring(aimY) }
            // Screen Studio's own spring pans in ~0.3 s (up to ~8 screen-widths/s), which reads as
            // a whip. Glide instead: a soft follow, on-screen speed capped at 1.5 screen-widths/s.
            let cap = 1.5 / max(level, 1)
            fx.append(Float(panX.step(to: aimX, time: 0.3, dt: dt, maxSpeed: cap)))
            fy.append(Float(panY.step(to: aimY, time: 0.3, dt: dt, maxSpeed: cap)))
            let fast = seg?.instant == true
            let isLoupe = seg?.kind == .loupe
            loupe.append(Float(lo.step(to: isLoupe ? 1 : 0, time: fast ? 0.001 : 0.18, dt: dt)))
            loupeScale.append(Float(ls.step(to: isLoupe ? (seg?.scale ?? 2) : Double(loupeScale.last ?? 2), time: 0.2, dt: dt)))
        }
    }

    struct ActivityGroup { var start: Double; var x: Double; var y: Double }

    /// Screen Studio's click groups for one zoom: cursor positions (thinned to moves of ~10 px,
    /// clicks always kept) taken in order, a new group starting whenever the next one would make
    /// the group wider or taller than 80% of what's visible at that zoom (Screen Studio
    /// uses half, which pans more often than it needs to). Each group's centre is
    /// weighted by how long the cursor spent at each point.
    static func activityGroups(samples: [CursorSample], in seg: ZoomSegment) -> [ActivityGroup] {
        var h = 0
        var events: [CursorSample] = [cursor(at: seg.start, in: samples, hint: &h)]
        var wasDown = events[0].down
        for s in samples where s.t > seg.start && s.t < seg.end {
            let last = events[events.count - 1]
            if s.down != wasDown || hypot(s.x - last.x, s.y - last.y) >= 0.003 { events.append(s) }
            wasDown = s.down
        }
        let maxSpan = 0.8 / max(seg.scale, 1)
        var groups: [[CursorSample]] = []
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        for e in events {
            if var g = groups.last,
               max(maxX, e.x) - min(minX, e.x) <= maxSpan, max(maxY, e.y) - min(minY, e.y) <= maxSpan {
                g.append(e)
                groups[groups.count - 1] = g
                minX = min(minX, e.x); maxX = max(maxX, e.x); minY = min(minY, e.y); maxY = max(maxY, e.y)
            } else {
                groups.append([e])
                minX = e.x; maxX = e.x; minY = e.y; maxY = e.y
            }
        }
        return groups.enumerated().map { i, g in
            let finish = i + 1 < groups.count ? groups[i + 1][0].t : nil
            var w = 0.0, sx = 0.0, sy = 0.0
            for (k, e) in g.enumerated() {
                let next = k + 1 < g.count ? g[k + 1].t : (finish ?? e.t + 0.1)
                let d = max(next - e.t, 0)
                w += d; sx += e.x * d; sy += e.y * d
            }
            return w > 0 ? ActivityGroup(start: g[0].t, x: sx / w, y: sy / w)
                         : ActivityGroup(start: g[0].t, x: g[0].x, y: g[0].y)
        }
    }

    /// The group under way at t (the latest one that has started), else the first one.
    static func group(at t: Double, in groups: [ActivityGroup]) -> ActivityGroup? {
        groups.last { $0.start <= t } ?? groups.first
    }

    /// How long a zoom takes to land: about half a second, measured from Screen Studio's own demo
    /// (a frame of lead-in, most of the move in the next ~0.1 s, then a soft settle).
    static func rampTime(_ s: ZoomSegment) -> Double {
        s.instant ? 0 : min(0.5, max(0.15, (s.end - s.start) / 2.2))
    }

    /// Zoom amount at t. Each zoom springs in from its start and springs back out so it's fully out
    /// at its end, with the same fast-then-settle shape both ways.
    static func zoomLevel(at t: Double, _ segs: [ZoomSegment]) -> Double {
        var level = 1.0
        for s in segs where t >= s.start && t < s.end {
            let r = rampTime(s)
            // Back-to-back zooms hand over without zooming out: the camera pans across instead.
            let joinedBefore = segs.contains { $0.id != s.id && abs($0.end - s.start) < 0.05 }
            let joinedAfter = segs.contains { $0.id != s.id && abs($0.start - s.end) < 0.05 }
            // In: spring from the start. Out: the same spring run forward from (end − r), so it
            // leaves quickly and lands softly on the full view right at the end.
            let pin = joinedBefore ? 1 : snap((t - s.start) / r)
            let pout = joinedAfter ? 1 : 1 - snap((t - (s.end - r)) / r)
            let p = r == 0 ? 1 : min(pin, pout)
            level = max(level, 1 + (s.scale - 1) * p)
        }
        return level
    }

    /// Critically damped spring from rest, normalised to reach exactly 1 at x = 1: a barely-there
    /// start, a fast middle, and a long gentle landing. This is the "camera operator" feel.
    static func snap(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        let w = 7.0
        func f(_ v: Double) -> Double { 1 - (1 + w * v) * exp(-w * v) }
        return f(u) / f(1)
    }

    static func ease(_ x: Double) -> Double { snap(x) }

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

    /// Where to zoom, the way Screen Studio does it: every press and release asks for a zoom from 0.3 s
    /// before it to 2.5 s after (clicks in the last second are ignored), and requests that overlap or are
    /// less than 2.5 s apart become one zoom. Where the camera looks inside a zoom is decided per
    /// frame from the click groups, so clicks far apart still share one zoom and the camera pans.
    static func autoSegments(samples: [CursorSample], duration: Double) -> [ZoomSegment] {
        var ranges: [(Double, Double)] = []
        var wasDown = false
        // Screen Studio's click list holds both the press and the release.
        for s in samples {
            if s.down != wasDown, s.t < duration - 1.0 {
                ranges.append((max(s.t - 0.3, 0.001), min(s.t + 2.5, duration - 0.8)))
            }
            wasDown = s.down
        }
        var merged: [(Double, Double)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) where r.1 > r.0 {
            if let last = merged.last, last.1 + 2.5 >= r.0 {
                merged[merged.count - 1].1 = max(last.1, r.1)
            } else {
                merged.append(r)
            }
        }
        // Screen Studio starts zooming out when its range ends; Closeup's zoom is fully out at the
        // segment's end, so the segment runs one zoom-out longer.
        return merged.map { r in
            var seg = ZoomSegment(start: r.0, end: r.1, scale: 2)
            seg.end = min(duration, r.1 + rampTime(seg))
            return seg
        }
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

    mutating func step(to target: Double, time: Double, dt: Double, maxSpeed: Double = .infinity) -> Double {
        let omega = 2 / max(time, 0.0001)
        let x = omega * dt
        let e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        // Limit how far ahead the target can pull (Unity's SmoothDamp maxSpeed), so long moves
        // become a steady glide rather than a fast snap.
        let maxChange = maxSpeed * time
        let change = min(max(value - target, -maxChange), maxChange)
        let target = value - change
        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * e
        value = target + (change + temp) * e
        return value
    }
}
