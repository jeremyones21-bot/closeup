import SwiftUI

/// Ruler with trim brackets and scrubbing, and a zoom track underneath.
/// Zooms are blocks: drag to move, drag an edge to resize, double-click empty track to add.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let inset: CGFloat = 14
    private enum Grab { case move, start, end }
    @State private var grab: (id: UUID, kind: Grab, start: Double, end: Double)?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - inset * 2)
            let d = max(model.duration, 0.01)
            let x = { (t: Double) -> CGFloat in inset + CGFloat(t / d) * width }
            let time = { (px: CGFloat) -> Double in max(0, min(d, Double((px - inset) / width) * d)) }

            VStack(spacing: 6) {
                ruler(width: width, x: x, time: time)
                    .frame(height: 26)
                zoomTrack(x: x, time: time, width: width)
                    .frame(height: 44)
            }
            .padding(.vertical, 8)
            // Dim the trimmed-off parts.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.18))
                        .frame(width: max(0, x(model.edits.trimStart) - inset))
                        .offset(x: inset)
                    Rectangle().fill(.black.opacity(0.18))
                        .frame(width: max(0, x(d) - x(model.trimEnd)))
                        .offset(x: x(model.trimEnd))
                }
                .allowsHitTesting(false)
            }
            // Playhead.
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5)
                    .offset(x: x(model.currentTime) - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Ruler

    private func ruler(width: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        let d = max(model.duration, 0.01)
        let step = Self.tickStep(duration: d, width: width)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                var t = 0.0
                while t <= d + 0.0001 {
                    let px = x(t)
                    ctx.fill(Path(CGRect(x: px, y: size.height - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.6)))
                    if px < size.width - 34 { ctx.draw(Text(Self.label(t, long: d >= 60)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary),
                             at: CGPoint(x: px + 3, y: 2), anchor: .topLeading) }
                    t += step
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.seek(to: time(v.location.x)) })

            trimHandle(at: x(model.edits.trimStart), leading: true)
                .gesture(DragGesture(coordinateSpace: .named("tl")).onChanged { v in
                    model.edits.trimStart = min(time(v.location.x), model.trimEnd - 0.5)
                    model.seek(to: model.edits.trimStart)
                })
            trimHandle(at: x(model.trimEnd), leading: false)
                .gesture(DragGesture(coordinateSpace: .named("tl")).onChanged { v in
                    let t = max(time(v.location.x), model.edits.trimStart + 0.5)
                    model.edits.trimEnd = t >= model.duration - 0.01 ? nil : t
                    model.seek(to: t)
                })
        }
        .coordinateSpace(name: "tl")
    }

    private func trimHandle(at px: CGFloat, leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 3 : 0, bottomLeadingRadius: leading ? 3 : 0,
                               bottomTrailingRadius: leading ? 0 : 3, topTrailingRadius: leading ? 0 : 3)
            .fill(Color.yellow)
            .frame(width: 7, height: 26)
            .offset(x: leading ? px - 7 : px)
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    // MARK: Zoom track

    private func zoomTrack(x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double, width: CGFloat) -> some View {
        let d = max(model.duration, 0.01)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                .frame(width: width)
                .offset(x: inset)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { p in model.addSegment(at: time(p.x + inset)) }
                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                    model.selected = nil
                    model.seek(to: time(p.x + inset))
                }

            // Where the clicks were, so you can see why a zoom is where it is.
            ForEach(Array(model.clicks.enumerated()), id: \.offset) { _, c in
                Circle().fill(Color.secondary.opacity(0.5))
                    .frame(width: 4, height: 4)
                    .offset(x: x(c) - 2, y: 36)
                    .allowsHitTesting(false)
            }

            ForEach(model.edits.segments) { seg in
                segmentBlock(seg, x: x, width: width, duration: d)
            }
        }
    }

    private func segmentBlock(_ seg: ZoomSegment, x: @escaping (Double) -> CGFloat, width: CGFloat, duration d: Double) -> some View {
        let selected = model.selected == seg.id
        let left = x(seg.start), right = x(seg.end)
        let perPoint = d / Double(width)

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(selected ? 0.32 : 0.18))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(selected ? 1 : 0.5), lineWidth: selected ? 1.5 : 1))
            if right - left > 44 {
                Text(String(format: "%.1f×", seg.scale))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 0) {
                edge(seg, .start, perPoint: perPoint)
                Spacer(minLength: 0)
                edge(seg, .end, perPoint: perPoint)
            }
        }
        .frame(width: max(8, right - left), height: 32)
        .offset(x: left, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { model.selected = seg.id; model.seek(to: seg.start) }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if grab?.id != seg.id { grab = (seg.id, .move, seg.start, seg.end); model.selected = seg.id }
            guard let g = grab else { return }
            let dt = Double(v.translation.width) * perPoint
            let len = g.end - g.start
            let s = max(0, min(d - len, g.start + dt))
            model.setSegment(seg.id, start: s, end: s + len)
        }.onEnded { _ in grab = nil })
    }

    private func edge(_ seg: ZoomSegment, _ kind: Grab, perPoint: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if grab?.id != seg.id { grab = (seg.id, kind, seg.start, seg.end); model.selected = seg.id }
                guard let g = grab else { return }
                let dt = Double(v.translation.width) * perPoint
                if kind == .start { model.setSegment(seg.id, start: g.start + dt, end: g.end) }
                else { model.setSegment(seg.id, start: g.start, end: g.end + dt) }
            }.onEnded { _ in grab = nil })
    }

    // MARK: Helpers

    static func tickStep(duration: Double, width: CGFloat) -> Double {
        let target = duration / Double(max(width, 1) / 70)   // a label every ~70pt
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300] where s >= target { return s }
        return 600
    }

    /// One style per ruler: seconds for short takes ("1.5s"), minutes for long ones ("1:30").
    static func label(_ t: Double, long: Bool) -> String {
        if long {
            let s = Int(t.rounded())
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return t.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(t))s" : String(format: "%.1fs", t)
    }
}
