import SwiftUI

/// Ruler (trim brackets, flags, scrubbing) over one track per kind of edit:
/// Zoom, Cut & Speed, Cursor, Mask, and Layout when there's a camera.
/// Drag a block to move it, drag an edge to resize, double-click empty track to add.
/// Right-click a block or a track for its menu; Delete removes the selected block.
struct TimelineView: View {
    @Bindable var model: EditorModel

    private let labelWidth: CGFloat = 8
    private let laneHeight: CGFloat = 44
    private enum Grab { case move, start, end }
    @State private var grab: (id: UUID, kind: Grab, start: Double, end: Double)?
    /// Where the pointer last was over a track, for "Add … Here" in the right-click menu.
    @State private var hoverTime: Double = 0
    @FocusState private var focused: Bool

    var lanes: [Lane] { model.visibleLanes }

    var body: some View {
        GeometryReader { geo in
            let inset = labelWidth + 8
            let width = max(1, geo.size.width - inset - 12)
            let d = max(model.duration, 0.01)
            let x = { (t: Double) -> CGFloat in inset + CGFloat(t / d) * width }
            let time = { (px: CGFloat) -> Double in max(0, min(d, Double((px - inset) / width) * d)) }

            VStack(alignment: .leading, spacing: 8) {
                ruler(width: width, inset: inset, x: x, time: time)
                    .frame(height: 30)
                ForEach(lanes) { lane in
                    laneRow(lane, width: width, inset: inset, x: x, time: time)
                        .frame(height: laneHeight)
                }
            }
            .padding(.vertical, 8)
            // Trimmed-off parts.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.45))
                        .frame(width: max(0, x(model.edits.trimStart) - inset))
                        .offset(x: inset)
                    Rectangle().fill(.black.opacity(0.45))
                        .frame(width: max(0, x(d) - x(model.trimEnd)))
                        .offset(x: x(model.trimEnd))
                }
                .allowsHitTesting(false)
            }
            // Playhead.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    Rectangle().fill(Studio.zoom).frame(width: 2)
                    Circle().fill(Studio.zoom).frame(width: 14, height: 14).offset(y: 2)
                }
                .frame(width: 14)
                .offset(x: x(model.currentTime) - 7)
                .allowsHitTesting(false)
            }
        }
        .background(Studio.background)
        .coordinateSpace(name: "tl")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard model.selection != nil else { return .ignored }
            model.deleteSelected()
            return .handled
        }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
    }

    private func select(_ lane: Lane, _ id: UUID) {
        model.selection = Selection(lane: lane, id: id)
        focused = true
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
                    model.trimming = true
                    model.edits.trimStart = min(time(v.location.x), model.trimEnd - 0.5)
                    model.seek(to: model.edits.trimStart)
                }.onEnded { _ in model.trimming = false })
            trimHandle(at: x(model.trimEnd), leading: false)
                .gesture(DragGesture(coordinateSpace: .named("tl")).onChanged { v in
                    model.trimming = true
                    let t = max(time(v.location.x), model.edits.trimStart + 0.5)
                    model.edits.trimEnd = t >= model.duration - 0.01 ? nil : t
                    model.seek(to: t)
                }.onEnded { _ in model.trimming = false })
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
            RoundedRectangle(cornerRadius: 10)
                .fill(trackColor(lane))
                .frame(width: width, height: laneHeight)
                .offset(x: inset)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .named("tl")) { p in model.add(lane, at: time(p.x)); focused = true }
                .onTapGesture(count: 1, coordinateSpace: .named("tl")) { p in
                    if lane == .zoom {
                        model.add(.zoom, at: time(p.x))
                    } else {
                        model.selection = nil
                        model.seek(to: time(p.x))
                    }
                    focused = true
                }
                .onContinuousHover(coordinateSpace: .named("tl")) { phase in
                    if case .active(let p) = phase { hoverTime = time(p.x) }
                }
                .contextMenu { laneMenu(lane) }

            if lane == .clip {
                // The kept part of the recording, as one long clip.
                let l = x(model.edits.trimStart), r = x(model.trimEnd)
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Studio.clip, Studio.clip.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        VStack(spacing: 1) {
                            Text("Clip").font(.system(size: 11, weight: .medium)).opacity(0.6)
                            Text("\(Int((model.editedDuration).rounded()))s  ·  1×").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(.white)
                    }
                    .frame(width: max(6, r - l), height: laneHeight)
                    .offset(x: l)
                    .allowsHitTesting(false)
            } else if model.items(lane).isEmpty {
                Text(hint(lane)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: width, height: laneHeight)
                    .offset(x: inset)
                    .allowsHitTesting(false)
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

    private func trackColor(_ lane: Lane) -> Color {
        switch lane {
        case .zoom: Studio.zoom.opacity(0.14)
        case .clip: Color.white.opacity(0.04)
        default: Color.white.opacity(0.05)
        }
    }

    private func hint(_ lane: Lane) -> String {
        switch lane {
        case .zoom: "Click or drag to add zoom on cursor"
        case .clip: ""
        case .cursor: "Double-click to hide the cursor"
        case .mask: "Double-click to add a mask"
        case .layout: "Double-click to change the camera layout"
        }
    }

    private func color(_ lane: Lane, _ id: UUID) -> Color {
        switch lane {
        case .zoom: Studio.zoom
        case .clip: model.isCut(id) ? Color(white: 0.16) : Color(red: 0.95, green: 0.72, blue: 0.25)
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
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(lane == .clip ? 0.9 : (selected ? 1 : 0.85)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
            if right - left > 34 {
                VStack(spacing: 1) {
                    Text(lane.title).font(.system(size: 11, weight: .medium)).opacity(0.7)
                    Text(model.label(lane, id)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6)
            }
            HStack(spacing: 0) {
                edge(lane, id, start, end, .start, perPoint: perPoint)
                Spacer(minLength: 0)
                edge(lane, id, start, end, .end, perPoint: perPoint)
            }
        }
        .frame(width: max(6, right - left), height: laneHeight)
        .offset(x: left)
        .contentShape(Rectangle())
        .onTapGesture { select(lane, id); model.seek(to: start) }
        .contextMenu { blockMenu(lane, id, start) }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if grab?.id != id { grab = (id, .move, start, end); select(lane, id) }
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
                if grab?.id != id { grab = (id, kind, start, end); select(lane, id) }
                guard let g = grab else { return }
                let dt = Double(v.translation.width) * perPoint
                if kind == .start { model.setSpan(lane, id, start: g.start + dt, end: g.end) }
                else { model.setSpan(lane, id, start: g.start, end: g.end + dt) }
            }.onEnded { _ in grab = nil })
    }

    // MARK: Right-click menus

    @ViewBuilder private func laneMenu(_ lane: Lane) -> some View {
        let t = hoverTime
        switch lane {
        case .zoom:
            Button("Add Zoom Here") { model.add(.zoom, at: t) }
            Button("Add Loupe Here") { model.add(.zoom, at: t, kind: "loupe") }
            Divider()
            Button("Recreate Automatic Zooms") { model.regenerateZooms() }
            Button("Remove All Zooms", role: .destructive) { model.removeAll(.zoom) }
                .disabled(model.edits.segments.isEmpty)
        case .clip:
            Button("Add Cut Here") { model.add(.clip, at: t) }
            Button("Add Speed-Up Here") { model.add(.clip, at: t, kind: "speed") }
            Divider()
            Button("Remove All Cuts and Speed Changes", role: .destructive) { model.removeAll(.clip) }
                .disabled(model.items(.clip).isEmpty)
        case .cursor:
            Button("Hide Cursor Here") { model.add(.cursor, at: t) }
            Button("Remove All", role: .destructive) { model.removeAll(.cursor) }
                .disabled(model.items(.cursor).isEmpty)
        case .mask:
            ForEach(MaskKind.allCases) { k in
                Button("Add \(k.label) Here") { model.add(.mask, at: t, kind: k.rawValue) }
            }
            Button("Remove All Masks", role: .destructive) { model.removeAll(.mask) }
                .disabled(model.items(.mask).isEmpty)
        case .layout:
            ForEach(CameraLayout.allCases) { l in
                Button("Add \(l.label) Here") { model.add(.layout, at: t, kind: l.rawValue) }
            }
            Button("Remove All Layouts", role: .destructive) { model.removeAll(.layout) }
                .disabled(model.items(.layout).isEmpty)
        }
    }

    @ViewBuilder private func blockMenu(_ lane: Lane, _ id: UUID, _ start: Double) -> some View {
        if lane == .zoom, let z = model.edits.segments.first(where: { $0.id == id }) {
            Menu("Zoom Amount") {
                ForEach([1.25, 1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { v in
                    Toggle(String(format: "%g×", v), isOn: Binding(get: { abs(z.scale - v) < 0.01 },
                                                                 set: { _ in model.updateZoom(id) { $0.scale = v } }))
                }
            }
            Picker("Type", selection: Binding(get: { z.kind }, set: { k in model.updateZoom(id) { $0.kind = k } })) {
                ForEach(ZoomSegment.Kind.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Instant (No Animation)", isOn: Binding(get: { z.instant }, set: { v in model.updateZoom(id) { $0.instant = v } }))
            Toggle("Follow Cursor", isOn: Binding(get: { z.focus == nil },
                                                  set: { v in model.updateZoom(id) { $0.focus = v ? nil : CGPoint(x: 0.5, y: 0.5) } }))
            Divider()
        }
        Button("Go to Start") { model.seek(to: start) }
        Button("Duplicate") { model.duplicate(lane, id) }
        Divider()
        Button("Delete", role: .destructive) {
            model.selection = Selection(lane: lane, id: id)
            model.deleteSelected()
        }
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
