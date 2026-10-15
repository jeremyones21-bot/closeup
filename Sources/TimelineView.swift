import SwiftUI

/// Ruler (trim brackets, flags, scrubbing) over one track per kind of edit:
/// Zoom, Cut & Speed, Cursor, Mask, and Layout when there's a camera.
/// Drag a block to move it, drag an edge to resize, double-click empty track to add.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let labelWidth: CGFloat = 78
    private let laneHeight: CGFloat = 26
    private enum Grab { case move, start, end }
    @State private var grab: (id: UUID, kind: Grab, start: Double, end: Double)?

    var lanes: [Lane] { Lane.allCases.filter { $0 != .layout || model.hasCamera } }

    var body: some View {
        GeometryReader { geo in
            let inset = labelWidth + 8
            let width = max(1, geo.size.width - inset - 12)
            let d = max(model.duration, 0.01)
            let x = { (t: Double) -> CGFloat in inset + CGFloat(t / d) * width }
            let time = { (px: CGFloat) -> Double in max(0, min(d, Double((px - inset) / width) * d)) }

            VStack(alignment: .leading, spacing: 4) {
                ruler(width: width, inset: inset, x: x, time: time)
                    .frame(height: 24)
                ForEach(lanes) { lane in
                    laneRow(lane, width: width, inset: inset, x: x, time: time)
                        .frame(height: laneHeight)
                }
            }
            .padding(.vertical, 6)
            // Trimmed-off parts.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.22))
                        .frame(width: max(0, x(model.edits.trimStart) - inset))
                        .offset(x: inset)
                    Rectangle().fill(.black.opacity(0.22))
                        .frame(width: max(0, x(d) - x(model.trimEnd)))
                        .offset(x: x(model.trimEnd))
                }
                .allowsHitTesting(false)
            }
            // Playhead.
            .overlay(alignment: .topLeading) {
                Rectangle().fill(Color.accentColor).frame(width: 1.5)
                    .offset(x: x(model.currentTime) - 0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .coordinateSpace(name: "tl")
    }

    // MARK: Ruler

    private func ruler(width: CGFloat, inset: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        let d = max(model.duration, 0.01)
        let step = Self.tickStep(duration: d, width: width)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                var t = 0.0
                while t <= d + 0.0001 {
                    let px = x(t)
                    ctx.fill(Path(CGRect(x: px, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                    if px < size.width - 34 {
                        ctx.draw(Text(Self.label(t, long: d >= 60)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary),
                                 at: CGPoint(x: px + 3, y: 1), anchor: .topLeading)
                    }
                    t += step
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.seek(to: time(v.location.x)) })

            ForEach(Array(model.flags.enumerated()), id: \.offset) { _, f in
                Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    .offset(x: x(f) - 2, y: 12)
                    .help("Flag at \(timecode(f))")
                    .onTapGesture { model.seek(to: f) }
            }

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
    }

    private func trimHandle(at px: CGFloat, leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 3 : 0, bottomLeadingRadius: leading ? 3 : 0,
                               bottomTrailingRadius: leading ? 0 : 3, topTrailingRadius: leading ? 0 : 3)
            .fill(Color.yellow)
            .frame(width: 7, height: 24)
            .offset(x: leading ? px - 7 : px)
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    // MARK: Lanes

    private func laneRow(_ lane: Lane, width: CGFloat, inset: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        let d = max(model.duration, 0.01)
        return ZStack(alignment: .topLeading) {
            Text(lane.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: labelWidth, height: laneHeight, alignment: .leading)
                .padding(.leading, 10)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .frame(width: width, height: laneHeight)
                .offset(x: inset)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .named("tl")) { p in model.add(lane, at: time(p.x)) }
                .onTapGesture(count: 1, coordinateSpace: .named("tl")) { p in
                    model.selection = nil
                    model.seek(to: time(p.x))
                }

            if lane == .zoom {
                ForEach(Array(model.clicks.enumerated()), id: \.offset) { _, c in
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3)
                        .offset(x: x(c) - 1.5, y: laneHeight - 5)
                        .allowsHitTesting(false)
                }
            }

            ForEach(model.items(lane), id: \.id) { item in
                block(lane, item.id, item.start, item.end, x: x, width: width, duration: d)
            }
        }
    }

    private func color(_ lane: Lane, _ id: UUID) -> Color {
        switch lane {
        case .zoom: .accentColor
        case .clip: model.isCut(id) ? .red : .orange
        case .cursor: .gray
        case .mask: model.edits.masks.first { $0.id == id }?.kind == .highlight ? .yellow : .purple
        case .layout: .teal
        }
    }

    private func block(_ lane: Lane, _ id: UUID, _ start: Double, _ end: Double, x: @escaping (Double) -> CGFloat,
                       width: CGFloat, duration d: Double) -> some View {
        let selected = model.selection == Selection(lane: lane, id: id)
        let left = x(start), right = x(end)
        let perPoint = d / Double(width)
        let tint = color(lane, id)
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(selected ? 0.38 : 0.22))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(selected ? 1 : 0.55), lineWidth: selected ? 1.5 : 1))
            if right - left > 34 {
                Text(model.label(lane, id)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(tint).lineLimit(1).padding(.horizontal, 4)
            }
            HStack(spacing: 0) {
                edge(lane, id, start, end, .start, perPoint: perPoint)
                Spacer(minLength: 0)
                edge(lane, id, start, end, .end, perPoint: perPoint)
            }
        }
        .frame(width: max(6, right - left), height: laneHeight - 4)
        .offset(x: left, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = Selection(lane: lane, id: id); model.seek(to: start) }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if grab?.id != id { grab = (id, .move, start, end); model.selection = Selection(lane: lane, id: id) }
            guard let g = grab else { return }
            let len = g.end - g.start
            let s = max(0, min(d - len, g.start + Double(v.translation.width) * perPoint))
            model.setSpan(lane, id, start: s, end: s + len)
        }.onEnded { _ in grab = nil })
    }

    private func edge(_ lane: Lane, _ id: UUID, _ start: Double, _ end: Double, _ kind: Grab, perPoint: Double) -> some View {
        Rectangle().fill(Color.clear).frame(width: 7).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if grab?.id != id { grab = (id, kind, start, end); model.selection = Selection(lane: lane, id: id) }
                guard let g = grab else { return }
                let dt = Double(v.translation.width) * perPoint
                if kind == .start { model.setSpan(lane, id, start: g.start + dt, end: g.end) }
                else { model.setSpan(lane, id, start: g.start, end: g.end + dt) }
            }.onEnded { _ in grab = nil })
    }

    // MARK: Helpers

    static func tickStep(duration: Double, width: CGFloat) -> Double {
        let target = duration / Double(max(width, 1) / 70)
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
