import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
    @Bindable var model: EditorModel
    @State private var tab = Tab.edit

    enum Tab: String, CaseIterable, Identifiable {
        case edit, style, camera, audio, captions
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .edit: "scissors"
            case .style: "paintpalette"
            case .camera: "video"
            case .audio: "waveform"
            case .captions: "captions.bubble"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Icon tabs with the name underneath: five text segments don't fit the inspector's width.
            HStack(spacing: 2) {
                ForEach(Tab.allCases.filter { $0 != .camera || model.hasCamera }) { t in
                    Button {
                        tab = t
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol).font(.system(size: 13))
                            Text(t.label).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Color.accentColor.opacity(0.18) : .clear))
                        .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t.label)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            Form {
                switch tab {
                case .edit: EditTab(model: model)
                case .style: StyleTab(model: model)
                case .camera: CameraTab(model: model)
                case .audio: AudioTab(model: model)
                case .captions: CaptionsTab(model: model)
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: model.selection) { if model.selection != nil { tab = .edit } }
    }
}

private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String? = nil) -> some View {
    LabeledContent(title) {
        HStack {
            Slider(value: value, in: range)
            if let format { Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 40, alignment: .trailing) }
        }
    }
}

// MARK: - Edit (selected item + adding things)

private struct EditTab: View {
    @Bindable var model: EditorModel
    @State private var typingMessage: String?

    var body: some View {
        if let sel = model.selection {
            selected(sel)
        }
        Section("Add at Playhead") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    add("Zoom", "plus.magnifyingglass") { model.add(.zoom, at: model.currentTime) }
                    add("Loupe", "magnifyingglass.circle") { model.add(.zoom, at: model.currentTime, kind: "loupe") }
                }
                GridRow {
                    add("Cut", "scissors") { model.add(.clip, at: model.currentTime) }
                    add("Speed Up", "hare") { model.add(.clip, at: model.currentTime, kind: "speed") }
                }
                GridRow {
                    add("Blur", "eye.slash") { model.add(.mask, at: model.currentTime, kind: "blur") }
                    add("Highlight", "rectangle.dashed") { model.add(.mask, at: model.currentTime, kind: "highlight") }
                }
                GridRow {
                    add("Hide Cursor", "cursorarrow.slash") { model.add(.cursor, at: model.currentTime) }
                    if model.hasCamera {
                        add("Layout", "rectangle.split.2x1") { model.add(.layout, at: model.currentTime) }
                    }
                }
            }
            Text("Or double-click a track. Delete removes the selected item.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Automatic") {
            Button("Redo Zooms from Clicks") { model.regenerateZooms() }
            Button("Speed Up Typing") {
                let n = model.speedUpTyping()
                typingMessage = model.keys.isEmpty
                    ? "No typing was logged. Allow Accessibility for Closeup before recording to detect typing."
                    : n == 0 ? "No long stretches of typing found." : "Sped up \(n) stretch\(n == 1 ? "" : "es") of typing."
            }
            if let typingMessage { Text(typingMessage).font(.caption).foregroundStyle(.secondary) }
            if !model.edits.segments.isEmpty {
                Button("Remove All Zooms", role: .destructive) { model.edits.segments = []; model.selection = nil }
            }
        }
        CropSection(model: model)
    }

    private func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading) }
    }

    @ViewBuilder private func selected(_ sel: Selection) -> some View {
        switch sel.lane {
        case .zoom:
            if let z = model.selectedZoom {
                Section("Zoom") {
                    Picker("Type", selection: Binding(get: { z.kind }, set: { var n = z; n.kind = $0; model.selectedZoom = n })) {
                        ForEach(ZoomSegment.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Amount") {
                        HStack {
                            Slider(value: Binding(get: { z.scale }, set: { v in var n = z; n.scale = (v * 4).rounded() / 4; model.selectedZoom = n }), in: 1.25...4)
                            Text(String(format: "%.2f×", z.scale)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Follows", selection: Binding(get: { z.focus == nil }, set: { follow in
                        var n = z; n.focus = follow ? nil : CGPoint(x: 0.5, y: 0.5); model.selectedZoom = n
                        if !follow { model.pickingFocus = true }
                    })) {
                        Text("Cursor").tag(true)
                        Text("Fixed point").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if z.focus != nil {
                        Button(model.pickingFocus ? "Click the preview…" : "Choose Point on Preview") { model.pickingFocus = true }
                    }
                    Toggle("Instant (no animation)", isOn: Binding(get: { z.instant }, set: { var n = z; n.instant = $0; model.selectedZoom = n }))
                    LabeledContent("Time", value: "\(timecode(z.start)) – \(timecode(z.end))")
                    Button("Delete Zoom", role: .destructive) { model.deleteSelected() }
                }
            }
        case .clip:
            if let s = model.selectedSpan(.clip) {
                Section(model.isCut(s.id) ? "Cut" : "Speed") {
                    if !model.isCut(s.id) {
                        Picker("Speed", selection: Binding(get: { s.rate }, set: { var n = s; n.rate = $0; model.updateSpan(.clip, n) })) {
                            ForEach([1.25, 1.5, 2, 3, 4, 8], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                        }
                    } else {
                        Text("This part is removed from the video.").foregroundStyle(.secondary)
                    }
                    LabeledContent("Time", value: "\(timecode(s.start)) – \(timecode(s.end))")
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }
            }
        case .cursor:
            if let s = model.selectedSpan(.cursor) {
                Section("Hidden Cursor") {
                    LabeledContent("Time", value: "\(timecode(s.start)) – \(timecode(s.end))")
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }
            }
        case .mask:
            if let s = model.selectedSpan(.mask) {
                Section(s.kind == .highlight ? "Highlight" : "Mask") {
                    Picker("Style", selection: Binding(get: { s.kind }, set: { var n = s; n.kind = $0; model.updateSpan(.mask, n) })) {
                        ForEach(MaskKind.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Drag the box on the preview to place it; drag its corner to resize.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Time", value: "\(timecode(s.start)) – \(timecode(s.end))")
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }
            }
        case .layout:
            if let s = model.selectedSpan(.layout) {
                Section("Layout") {
                    Picker("Layout", selection: Binding(get: { s.layout }, set: { var n = s; n.layout = $0; model.updateSpan(.layout, n) })) {
                        ForEach(CameraLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    LabeledContent("Time", value: "\(timecode(s.start)) – \(timecode(s.end))")
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }
            }
        }
    }
}

private struct CropSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Crop") {
            Toggle("Crop the recording", isOn: Binding(get: { model.edits.crop != nil }, set: { on in
                model.edits.crop = on ? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) : nil
            }))
            if let c = model.edits.crop {
                slider("Left", Binding(get: { c.minX }, set: { model.edits.crop = CGRect(x: min($0, c.maxX - 0.1), y: c.minY, width: c.maxX - min($0, c.maxX - 0.1), height: c.height) }), 0...0.9)
                slider("Right", Binding(get: { c.maxX }, set: { model.edits.crop = CGRect(x: c.minX, y: c.minY, width: max(0.1, $0 - c.minX), height: c.height) }), 0.1...1)
                slider("Top", Binding(get: { c.minY }, set: { model.edits.crop = CGRect(x: c.minX, y: min($0, c.maxY - 0.1), width: c.width, height: c.maxY - min($0, c.maxY - 0.1)) }), 0...0.9)
                slider("Bottom", Binding(get: { c.maxY }, set: { model.edits.crop = CGRect(x: c.minX, y: c.minY, width: c.width, height: max(0.1, $0 - c.minY)) }), 0.1...1)
            }
        }
    }
}

// MARK: - Style

private struct StyleTab: View {
    @Bindable var model: EditorModel

    var body: some View {
        PresetSection(model: model)
        Section("Backdrop") {
            BackdropGrid(selection: $model.edits.style.backdrop)
            if model.edits.style.backdrop == .wallpaper {
                WallpaperPicker(path: $model.edits.style.imagePath)
            }
            if model.edits.style.backdrop == .image {
                Button(model.edits.style.imagePath == nil ? "Choose Image…" : "Change Image…") { chooseImage() }
            }
        }
        Section("Frame") {
            Picker("Size", selection: $model.edits.style.aspect) {
                ForEach(Aspect.allCases) { Text($0.label).tag($0) }
            }
            slider("Padding", $model.edits.style.padding, 0...0.2)
            slider("Corners", $model.edits.style.corner, 0...0.04)
            slider("Inset", $model.edits.style.inset, 0...0.03)
            if model.edits.style.inset > 0.0005 {
                Picker("Inset colour", selection: $model.edits.style.insetDark) {
                    Text("Light").tag(false); Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        Section("Shadow") {
            slider("Strength", $model.edits.style.shadow, 0...1)
            slider("Softness", $model.edits.style.shadowSoftness, 0.002...0.08)
            slider("Distance", $model.edits.style.shadowDistance, 0...0.05)
            slider("Angle", $model.edits.style.shadowAngle, 0...360, format: "%.0f°")
        }
        Section("Cursor") {
            Picker("Style", selection: $model.edits.style.cursorStyle) {
                ForEach(CursorStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Size", $model.edits.style.cursorScale, 0.8...3.5, format: "%.1f×")
            slider("Smoothing", $model.edits.style.cursorSmoothing, 0...1)
            Toggle("Shrink on click", isOn: $model.edits.style.clickEffect)
            Toggle("Ripple on click", isOn: $model.edits.style.clickRipple)
            Toggle("Click sound", isOn: $model.edits.style.clickSound)
            Toggle("Motion blur", isOn: $model.edits.style.motionBlur)
            Toggle("Hide when still", isOn: $model.edits.style.hideIdleCursor)
            Toggle("Loop back to start", isOn: $model.edits.style.loopCursor)
            Toggle("Show keyboard shortcuts", isOn: $model.edits.style.showShortcuts)
        }
    }

    private func chooseImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let url = p.url else { return }
        // Keep a copy with the project so it still works if the original moves.
        let dest = model.project.url.appendingPathComponent("backdrop.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        model.edits.style.imagePath = dest.path
    }
}

private struct WallpaperPicker: View {
    @Binding var path: String?
    @State private var walls: [URL] = []

    var body: some View {
        Picker("Wallpaper", selection: $path) {
            Text("Your desktop picture").tag(String?.none)
            ForEach(walls, id: \.self) { u in Text(u.deletingPathExtension().lastPathComponent).tag(Optional(u.path)) }
        }
        .onAppear { walls = Compositor.systemWallpapers() }
    }
}

struct BackdropGrid: View {
    @Binding var selection: Backdrop

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 8), count: 5), alignment: .leading, spacing: 8) {
            ForEach(Backdrop.allCases) { b in
                Button {
                    selection = b
                } label: {
                    swatch(b)
                        .frame(width: 38, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(selection == b ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selection == b ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help(b == .wallpaper ? "macOS wallpaper" : b == .image ? "Your own image" : b.label)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func swatch(_ b: Backdrop) -> some View {
        if b == .wallpaper || b == .image {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: b == .wallpaper ? "photo" : "photo.badge.plus").foregroundStyle(.secondary)
            }
        } else {
            let (t, bot) = b.colors
            LinearGradient(colors: [Color(red: t.0, green: t.1, blue: t.2), Color(red: bot.0, green: bot.1, blue: bot.2)],
                           startPoint: .topLeading, endPoint: .bottom)
        }
    }
}

/// Save the current look as a preset, apply one, or mark one as the default for new recordings.
struct PresetSection: View {
    @Bindable var model: EditorModel
    @State private var presets = PresetStore.all()
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Section("Preset") {
            Menu(presets.first { $0.style == model.edits.style }?.name ?? "Custom") {
                ForEach(presets) { p in
                    Button(p.isDefault ? "\(p.name) (default)" : p.name) { model.edits.style = p.style }
                }
                if !presets.isEmpty { Divider() }
                Button("Save Current Look as Preset…") { name = ""; naming = true }
                Button("Import Preset…") { _ = PresetStore.importFile(); presets = PresetStore.all() }
                if let current = presets.first(where: { $0.style == model.edits.style }) {
                    Divider()
                    Button(current.isDefault ? "Stop Using as Default" : "Use for New Recordings") {
                        PresetStore.setDefault(current.isDefault ? nil : current)
                        presets = PresetStore.all()
                    }
                    Button("Share Preset File…") { PresetStore.reveal(current) }
                    Button("Delete Preset", role: .destructive) { PresetStore.delete(current); presets = PresetStore.all() }
                }
            }
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") {
                guard !name.isEmpty else { return }
                PresetStore.save(Preset(name: name, style: model.edits.style))
                presets = PresetStore.all()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the backdrop, frame, cursor and camera settings.")
        }
        .onAppear { presets = PresetStore.all() }
    }
}

// MARK: - Camera

private struct CameraTab: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Camera") {
            Toggle("Show camera", isOn: $model.edits.style.showCamera)
            Picker("Position", selection: $model.edits.style.cameraCorner) {
                ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
            }
            Picker("Shape", selection: $model.edits.style.cameraShape) {
                ForEach(CameraShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Size", $model.edits.style.cameraSize, 0.12...0.45)
            Toggle("Mirror", isOn: $model.edits.style.cameraMirror)
            Text("Change layouts over time on the Layout track: overlay, fullscreen camera, split screen or screen only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Presenter") {
            Toggle("Remove background (cutout)", isOn: $model.edits.style.cameraCutout)
            Toggle("Follow my face", isOn: $model.edits.style.faceTracking)
            Toggle("Hide camera when I'm not talking", isOn: $model.edits.style.hideCameraInSilence)
            if model.edits.style.faceTracking && model.analysis.faces.isEmpty {
                Text("Finding your face in the recording…").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Look") {
            Picker("Colour", selection: $model.edits.style.cameraLook) {
                ForEach(CameraLook.allCases) { Text($0.label).tag($0) }
            }
            slider("Sharpen", $model.edits.style.cameraSharpen, 0...1)
            Toggle("Crop camera", isOn: Binding(get: { model.edits.style.cameraCrop != nil }, set: {
                model.edits.style.cameraCrop = $0 ? CGRect(x: 0.15, y: 0, width: 0.7, height: 1) : nil
            }))
            if let c = model.edits.style.cameraCrop {
                slider("Width", Binding(get: { c.width }, set: { w in
                    let nw = max(0.2, min(1, w)); model.edits.style.cameraCrop = CGRect(x: (1 - nw) / 2, y: c.minY, width: nw, height: c.height)
                }), 0.2...1)
                slider("Height", Binding(get: { c.height }, set: { h in
                    let nh = max(0.2, min(1, h)); model.edits.style.cameraCrop = CGRect(x: c.minX, y: (1 - nh) / 2, width: c.width, height: nh)
                }), 0.2...1)
            }
            Text("Reactions (hearts, fireworks, thumbs up) come from macOS: turn them on in Control Center › Video Effects while recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @Bindable var model: EditorModel
    @State private var processing = false
    @State private var message: String?
    @State private var script = ""
    @State private var voice = AudioTools.voices[0]
    @State private var speaking = false

    var body: some View {
        Section("Recording") {
            LabeledContent("Volume") {
                HStack {
                    Slider(value: $model.edits.volume, in: 0...2)
                    Text("\(Int(model.edits.volume * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Voice", selection: Binding(get: { model.edits.voiceMode }, set: { mode in
                Task {
                    processing = true
                    defer { processing = false }
                    do {
                        try await AudioTools.processVoice(model.project, mode: mode)
                        model.edits.voiceMode = mode
                        message = nil
                    } catch { message = error.localizedDescription }
                }
            })) {
                ForEach(VoiceMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(processing)
            Text(processing ? "Cleaning up your voice on this Mac…" : model.edits.voiceMode.detail).font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        Section("Music") {
            if let m = model.edits.musicFile {
                LabeledContent("Track", value: m.replacingOccurrences(of: "music-", with: ""))
                slider("Music volume", $model.edits.musicVolume, 0...1)
                Text("Loops to fill the video and dips under your voice.").font(.caption).foregroundStyle(.secondary)
                Button("Remove Music", role: .destructive) { model.edits.musicFile = nil }
            } else {
                Button("Add Music…") { chooseMusic() }
            }
        }
        Section("Voiceover") {
            if AudioTools.kokoroAvailable {
                TextField("Type what to say at the playhead", text: $script, axis: .vertical).lineLimit(2...5)
                Picker("Voice", selection: $voice) { ForEach(AudioTools.voices, id: \.self) { Text($0).tag($0) } }
                Button(speaking ? "Generating…" : "Add Voiceover at \(timecode(model.currentTime))") {
                    let text = script, v = voice, at = model.currentTime
                    Task {
                        speaking = true
                        defer { speaking = false }
                        do {
                            let file = try await AudioTools.generateVoiceover(text, voice: v, in: model.project)
                            model.edits.voiceovers.append(Voiceover(start: at, text: text, voice: v, file: file))
                            script = ""
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(script.trimmingCharacters(in: .whitespaces).isEmpty || speaking)
                ForEach(model.edits.voiceovers) { v in
                    HStack {
                        Text("\(timecode(v.start))  \(v.text)").lineLimit(1)
                        Spacer()
                        Button { model.edits.voiceovers.removeAll { $0.id == v.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Text("Generated on this Mac with the Kokoro voice model.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Voiceover needs the Kokoro voice model, which isn't installed on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseMusic() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        guard p.runModal() == .OK, let url = p.url else { return }
        let name = "music-\(url.lastPathComponent)"
        let dest = model.project.url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        model.edits.musicFile = name
    }
}

// MARK: - Captions and transcript

private struct CaptionsTab: View {
    @Bindable var model: EditorModel
    @State private var selectedWords = Set<String>()   // "line.word" keys

    var body: some View {
        Section("Captions") {
            if model.analysis.captions.isEmpty {
                Button(model.analysis.transcribing ? "Transcribing on this Mac…" : "Generate Captions") { transcribe() }
                    .disabled(model.analysis.transcribing)
                if let e = model.analysis.transcriptError { Text(e).font(.caption).foregroundStyle(.red) }
                Text("Speech is turned into text on this Mac. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Show captions", isOn: $model.edits.style.captions)
                Picker("Style", selection: $model.edits.style.captionStyle) {
                    ForEach(CaptionStyle.allCases) { Text($0.label).tag($0) }
                }
                Button("Export Subtitles (.srt)…") { exportSRT() }
                Button("Transcribe Again") { transcribe() }.disabled(model.analysis.transcribing)
            }
        }
        if !model.analysis.captions.isEmpty {
            Section("Edit by Transcript") {
                HStack {
                    Button("Remove Filler Words") { removeFillers() }
                    Button("Shorten Pauses") { shortenPauses() }
                }
                Text("Click words to select them (⌘-click for more), then cut them out of the video.").font(.caption).foregroundStyle(.secondary)
                if !selectedWords.isEmpty {
                    Button("Cut \(selectedWords.count) Selected Word\(selectedWords.count == 1 ? "" : "s")", role: .destructive) { cutSelected() }
                }
                TranscriptView(model: model, selected: $selectedWords)
            }
        }
    }

    private func transcribe() {
        Task {
            model.analysis.transcribing = true
            model.analysis.transcriptError = nil
            defer { model.analysis.transcribing = false }
            do {
                model.analysis.captions = try await Analyzer.transcribe(model.project)
                model.edits.style.captions = true
                model.refreshScene()
            } catch {
                model.analysis.transcriptError = error.localizedDescription
            }
        }
    }

    private func words() -> [(key: String, word: Caption.Word)] {
        model.analysis.captions.enumerated().flatMap { li, line in
            line.words.enumerated().map { ("\(li).\($0.offset)", $0.element) }
        }
    }

    private func cutSelected() {
        let chosen = words().filter { selectedWords.contains($0.key) }.map(\.word).sorted { $0.start < $1.start }
        // Merge neighbouring words into one cut.
        var spans: [Span] = []
        for w in chosen {
            if let last = spans.last, w.start - last.end < 0.25 { spans[spans.count - 1].end = w.end }
            else { spans.append(Span(start: w.start, end: w.end)) }
        }
        model.edits.cuts += spans
        selectedWords = []
    }

    private func removeFillers() {
        let fillers = words().map(\.word).filter {
            Analyzer.fillers.contains($0.text.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        model.edits.cuts += fillers.map { Span(start: max(0, $0.start - 0.03), end: $0.end + 0.03) }
    }

    /// Gaps longer than 0.8 s between words are cut down to 0.35 s.
    private func shortenPauses() {
        let ws = words().map(\.word).sorted { $0.start < $1.start }
        var cuts: [Span] = []
        for (a, b) in zip(ws, ws.dropFirst()) where b.start - a.end > 0.8 {
            cuts.append(Span(start: a.end + 0.175, end: b.start - 0.175))
        }
        model.edits.cuts += cuts.filter { c in !model.edits.cuts.contains { $0.start < c.end && $0.end > c.start } }
    }

    private func exportSRT() {
        let p = NSSavePanel()
        p.nameFieldStringValue = model.project.name + ".srt"
        p.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? model.project.srt(model.analysis.captions, timeline: model.timeline).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TranscriptView: View {
    @Bindable var model: EditorModel
    @Binding var selected: Set<String>

    var body: some View {
        // Flowing words; cut ones struck through, the current one underlined.
        FlowLayout(spacing: 3) {
            ForEach(Array(model.analysis.captions.enumerated()), id: \.offset) { li, line in
                ForEach(Array(line.words.enumerated()), id: \.offset) { wi, w in
                    let key = "\(li).\(wi)"
                    let cut = model.timeline.isCut((w.start + w.end) / 2)
                    let now = model.currentTime >= w.start && model.currentTime < w.end
                    Text(w.text)
                        .strikethrough(cut)
                        .foregroundStyle(cut ? .secondary : .primary)
                        .underline(now)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(selected.contains(key) ? Color.accentColor.opacity(0.3) : .clear))
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                                if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                            } else {
                                selected = selected == [key] ? [] : [key]
                                model.seek(to: w.start)
                            }
                        }
                }
            }
        }
    }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
