import SwiftUI

struct Inspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        Form {
            if let seg = model.selectedSegment {
                Section("Zoom") {
                    LabeledContent("Amount") {
                        HStack {
                            Slider(value: Binding(get: { seg.scale }, set: { v in
                                var s = seg; s.scale = (v * 4).rounded() / 4; model.selectedSegment = s
                            }), in: 1.25...4)
                            Text(String(format: "%.2f×", seg.scale)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Time", value: "\(timecode(seg.start)) – \(timecode(seg.end))")
                    Button("Delete Zoom", role: .destructive) { model.deleteSelected() }
                }
            } else {
                Section("Zoom") {
                    Text("Zooms follow the cursor. Click one on the timeline to change it, or double-click empty track to add one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Redo Zooms from Clicks") { model.regenerateZooms() }
                    if !model.edits.segments.isEmpty {
                        Button("Remove All Zooms", role: .destructive) { model.edits.segments = []; model.selected = nil }
                    }
                }
            }

            if model.hasCamera {
                Section("Camera") {
                    Toggle("Show camera", isOn: $model.edits.style.showCamera)
                    Group {
                        Picker("Position", selection: $model.edits.style.cameraCorner) {
                            ForEach(CameraCorner.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Shape", selection: $model.edits.style.cameraShape) {
                            ForEach(CameraShape.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        slider("Size", $model.edits.style.cameraSize, 0.12...0.45)
                        Toggle("Mirror", isOn: $model.edits.style.cameraMirror)
                    }
                    .disabled(!model.edits.style.showCamera)
                }
            }

            PresetSection(model: model)

            Section("Backdrop") {
                BackdropGrid(selection: $model.edits.style.backdrop)
            }

            Section("Frame") {
                Picker("Size", selection: $model.edits.style.aspect) {
                    ForEach(Aspect.allCases) { Text($0.label).tag($0) }
                }
                slider("Padding", $model.edits.style.padding, 0...0.2)
                slider("Corners", $model.edits.style.corner, 0...0.04)
                slider("Shadow", $model.edits.style.shadow, 0...1)
            }

            Section("Cursor") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $model.edits.style.cursorScale, in: 0.8...3.5)
                        Text(String(format: "%.1f×", model.edits.style.cursorScale)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                slider("Smoothing", $model.edits.style.cursorSmoothing, 0...1)
                Toggle("Shrink on click", isOn: $model.edits.style.clickEffect)
                Toggle("Hide when still", isOn: $model.edits.style.hideIdleCursor)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
        }
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
                .help(b == .wallpaper ? "Your desktop picture" : b.label)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func swatch(_ b: Backdrop) -> some View {
        if b == .wallpaper {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "photo").foregroundStyle(.secondary)
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
