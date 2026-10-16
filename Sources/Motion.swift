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
            press.append(Float(p.step(to: raw.down ? 1 : 0, time: raw.down ? 0.025 : 0.07, dt: dt)))   // snap down, ease back
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
            let follow = classic?.instant == true ? 0.001 : 0.16
            fx.append(Float(fxs.step(to: aimX, time: follow, dt: dt)))
            fy.append(Float(fys.step(to: aimY, time: follow, dt: dt)))
            _ = z
            let fast = seg?.instant == true
            let isLoupe = seg?.kind == .loupe
            loupe.append(Float(lo.step(to: isLoupe ? 1 : 0, time: fast ? 0.001 : 0.18, dt: dt)))
            loupeScale.append(Float(ls.step(to: isLoupe ? (seg?.scale ?? 2) : Double(loupeScale.last ?? 2), time: 0.2, dt: dt)))
        }
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

    /// Where to zoom, from what happened while recording.
    ///
    /// Cues: clicks (inside the recording, not the menu bar, not the final Stop click), plus
    /// moments where the cursor comes to rest on something for a while without clicking.
    /// A cue joins the current zoom only if it's soon after the last one *and* close enough to
    /// still be on screen at that zoom; a cue elsewhere starts a new zoom instead of dragging the
    /// camera across the whole screen. Each zoom lands as its first click happens, holds a beat
    /// after the last, and is capped so nothing stays zoomed for ages.
    static func autoSegments(samples: [CursorSample], duration: Double) -> [ZoomSegment] {
        struct Cue { var t: Double; var x: Double; var y: Double; var weight: Double }
        var cues: [Cue] = []

        // Clicks.
        var wasDown = false
        for s in samples {
            if s.down && !wasDown, s.t > 0.3, s.t < duration - 1.0,
               s.x >= 0, s.x <= 1, s.y >= 0.035, s.y <= 1 {
                cues.append(Cue(t: s.t, x: s.x, y: s.y, weight: 1))
            }
            wasDown = s.down
        }

        // Rests: the cursor travels somewhere, then stays within a small radius for 0.6–3 s.
        var runStart = 0
        func closeRun(_ a: Int, _ b: Int) {
            guard b - a >= 2 else { return }
            let d = samples[b - 1].t - samples[a].t
            guard d >= 0.6, d <= 3 else { return }
            let mid = (samples[a].t + samples[b - 1].t) / 2
            guard mid > 0.5, mid < duration - 1.5 else { return }
            let xs = samples[a..<b].map(\.x), ys = samples[a..<b].map(\.y)
            let x = xs.reduce(0, +) / Double(xs.count), y = ys.reduce(0, +) / Double(ys.count)
            guard x >= 0, x <= 1, y >= 0.035, y <= 1 else { return }
            // Only count rests that follow real travel (not idling where it already was).
            let before = samples[max(0, a - 30)..<a]
            let travelled = before.contains { hypot($0.x - x, $0.y - y) > 0.12 }
            if travelled { cues.append(Cue(t: samples[a].t + 0.15, x: x, y: y, weight: 0.5)) }
        }
        for i in 1..<max(samples.count, 1) {
            if hypot(samples[i].x - samples[runStart].x, samples[i].y - samples[runStart].y) > 0.02 {
                closeRun(runStart, i)
                runStart = i
            }
        }
        if !samples.isEmpty { closeRun(runStart, samples.count) }
        cues.sort { $0.t < $1.t }
        // A rest right before or after a click is the same moment; keep the click.
        cues = cues.filter { c in c.weight == 1 || !cues.contains { $0.weight == 1 && abs($0.t - c.t) < 1.5 } }

        // Group cues that are close in time and in place.
        let scale = 2.0
        let reach = 0.5 / scale * 0.8          // how far apart two points can be and both stay in view
        var groups: [[Cue]] = []
        for c in cues {
            if var g = groups.last, let last = g.last, c.t - last.t < 3.0 {
                let cx = g.map(\.x).reduce(0, +) / Double(g.count), cy = g.map(\.y).reduce(0, +) / Double(g.count)
                if abs(c.x - cx) < reach && abs(c.y - cy) < reach {
                    g.append(c)
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append([c])
        }
        // A lone rest is a weak cue; only rests that come with clicks, or long ones, make zooms.
        groups = groups.filter { $0.contains { $0.weight == 1 } || $0.count >= 2 }

        var segs: [ZoomSegment] = []
        var centers: [(Double, Double)] = []
        for g in groups {
            let first = g.first!.t, last = g.last!.t
            let cx = g.map(\.x).reduce(0, +) / Double(g.count), cy = g.map(\.y).reduce(0, +) / Double(g.count)
            // Land as the first click happens (the zoom takes ~0.45 s), hold 1.8 s after the last,
            // and stay at least 2.4 s so it reads as a deliberate zoom, not a twitch.
            let start = max(0, first - 0.5)
            var end = min(duration - 0.3, max(last + 1.8, start + 2.4))
            end = min(end, start + 9)
            guard end - start > 1.0 else { continue }
            if let prev = segs.last, let pc = centers.last, start < prev.end + 1.2 {
                if hypot(cx - pc.0, cy - pc.1) < 0.45 {
                    // Nearby and soon: one longer zoom; the camera follows across.
                    segs[segs.count - 1].end = min(max(prev.end, end), prev.start + 12)
                    centers[centers.count - 1] = ((pc.0 + cx) / 2, (pc.1 + cy) / 2)
                } // Far away and soon: there's no time to zoom out and back in, and chasing it
                  // means a whip pan across the screen. Stay with the earlier zoom and skip this one.
                continue
            }
            segs.append(ZoomSegment(start: start, end: end, scale: scale))
            centers.append((cx, cy))
        }
        return segs
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
