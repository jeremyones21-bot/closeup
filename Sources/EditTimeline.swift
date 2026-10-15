import AVFoundation

/// Maps between recording time (what the editor's timeline shows) and output time (what plays
/// and exports), after trimming, cutting and speed changes.
///
/// The output is a list of pieces of the recording played back to back, each at its own rate.
struct EditTimeline: Sendable, Equatable {
    struct Piece: Sendable, Equatable {
        let srcStart: Double
        let srcEnd: Double
        let rate: Double
        let outStart: Double
        var outEnd: Double { outStart + (srcEnd - srcStart) / rate }
    }

    let pieces: [Piece]
    var duration: Double { pieces.last?.outEnd ?? 0 }

    init(edits: Edits, sourceDuration: Double) {
        let end = min(edits.trimEnd ?? sourceDuration, sourceDuration)
        // Kept ranges: trim window minus cuts.
        var kept: [(Double, Double)] = [(edits.trimStart, end)]
        for c in edits.cuts.sorted(by: { $0.start < $1.start }) {
            kept = kept.flatMap { r -> [(Double, Double)] in
                guard c.end > r.0, c.start < r.1 else { return [r] }
                return [(r.0, c.start), (c.end, r.1)].filter { $0.1 - $0.0 > 0.01 }
            }
        }
        // Split kept ranges at speed boundaries.
        let speeds = edits.speeds.sorted { $0.start < $1.start }
        var out: [Piece] = []
        var t = 0.0
        for (a, b) in kept {
            var cuts = [a, b]
            for s in speeds { if s.start > a && s.start < b { cuts.append(s.start) }; if s.end > a && s.end < b { cuts.append(s.end) } }
            cuts.sort()
            for (x, y) in zip(cuts, cuts.dropFirst()) where y - x > 0.005 {
                let mid = (x + y) / 2
                let rate = speeds.first { mid >= $0.start && mid < $0.end }?.rate ?? 1
                let p = Piece(srcStart: x, srcEnd: y, rate: max(0.1, rate), outStart: t)
                out.append(p)
                t = p.outEnd
            }
        }
        pieces = out
    }

    /// Recording time shown at output time `t`.
    func source(at t: Double) -> Double {
        guard let p = pieces.last(where: { $0.outStart <= t + 1e-6 }) ?? pieces.first else { return t }
        return min(p.srcEnd, p.srcStart + (t - p.outStart) * p.rate)
    }

    /// Output time of recording time `s`, snapping into the next kept piece if `s` was cut.
    func output(at s: Double) -> Double {
        for p in pieces {
            if s < p.srcStart { return p.outStart }
            if s <= p.srcEnd { return p.outStart + (s - p.srcStart) / p.rate }
        }
        return duration
    }

    func isCut(_ s: Double) -> Bool { !pieces.contains { s >= $0.srcStart && s <= $0.srcEnd } }

    /// Lays `track` into `into` piece by piece. `offset` shifts the track against the recording
    /// (the camera started a little after the screen).
    func insert(_ track: AVAssetTrack, trackDuration: Double, offset: Double = 0, into dest: AVMutableCompositionTrack) {
        for p in pieces {
            // Part of this piece the track covers, in the track's own time.
            let a = max(p.srcStart - offset, 0), b = min(p.srcEnd - offset, trackDuration)
            guard b - a > 0.005 else { continue }
            let at = p.outStart + (a + offset - p.srcStart) / p.rate
            let src = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 6000), end: CMTime(seconds: b, preferredTimescale: 6000))
            let outAt = CMTime(seconds: at, preferredTimescale: 6000)
            do {
                try dest.insertTimeRange(src, of: track, at: outAt)
                if abs(p.rate - 1) > 0.001 {
                    dest.scaleTimeRange(CMTimeRange(start: outAt, duration: src.duration),
                                        toDuration: CMTime(seconds: (b - a) / p.rate, preferredTimescale: 6000))
                }
            } catch {
                continue
            }
        }
    }
}
