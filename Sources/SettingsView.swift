import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            EditingSettings().tabItem { Label("Editing", systemImage: "pencil.tip.crop.circle") }
            ExportSettings().tabItem { Label("Quick Export", systemImage: "square.and.arrow.up") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command.circle") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 640)
    }
}

/// One row: title + explanation on the left, control on the right.
private struct Row<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private func chooseFolder(_ start: URL, _ done: (URL) -> Void) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.directoryURL = start
    p.prompt = "Choose"
    if p.runModal() == .OK, let url = p.url { done(url) }
}

private func displayPath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
}

struct GeneralSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var confirmReset = false

    var body: some View {
        Form {
            Row(title: "Start Closeup at login", detail: "Open Closeup automatically when you log in.") {
                Toggle("", isOn: $prefs.startAtLogin).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Hide Dock icon", detail: "Hide the Dock icon when no recording is open and nothing is being recorded. Closeup stays in the menu bar.") {
                Toggle("", isOn: $prefs.hideDockIconWhenIdle).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Usage data", detail: "Closeup doesn't collect any. Nothing about you or your recordings leaves this Mac.") { EmptyView() }
            Divider()
            HStack {
                Spacer()
                Button("Reset Preferences…", role: .destructive) { confirmReset = true }
                Spacer()
            }
        }
        .padding(24)
        .confirmationDialog("Reset all preferences and shortcuts?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Prefs.shared.reset(); Hotkeys.shared.reload() }
        } message: {
            Text("Your recordings aren't touched. Closeup goes back to its default settings the next time it opens.")
        }
    }
}

struct RecordingSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Row(title: "Save new projects to", detail: displayPath(prefs.saveDirectory)) {
                Button("Change…") { chooseFolder(prefs.saveDirectory) { prefs.saveDirectory = $0; AppState.shared.refresh() } }
            }
            Row(title: "Highlight recorded area during recording", detail: "Dims the parts of the screen that aren't being recorded.") {
                Toggle("", isOn: $prefs.highlightRecordedArea).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Create zooms automatically", detail: "Adds zooms where you clicked in every new recording.") {
                Toggle("", isOn: $prefs.autoZooms).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Show recording widget", detail: "A small floating control while recording, to finish, pause, restart or cancel.") {
                Toggle("", isOn: $prefs.showRecordingWidget).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "After recording", detail: "What happens when you stop.") {
                Picker("", selection: $prefs.afterRecording) {
                    ForEach(Prefs.AfterRecording.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Row(title: "Maximum camera resolution", detail: "If your camera supports it. Higher uses more of the Mac while recording.") {
                Picker("", selection: $prefs.cameraResolution) {
                    ForEach(Prefs.CameraResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .padding(24)
    }
}

struct EditingSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Row(title: "Use last project's settings for new recordings",
                detail: "New recordings start with the look of the last one you edited. A preset marked as default wins over this.") {
                Toggle("", isOn: $prefs.useLastProjectSettings).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Autosave", detail: "Closeup saves every change as you make it. There's nothing to turn on.") { EmptyView() }
            Row(title: "Save presets in", detail: displayPath(prefs.presetsDirectory)) {
                Button("Change…") { chooseFolder(prefs.presetsDirectory) { prefs.presetsDirectory = $0 } }
            }
        }
        .padding(24)
    }
}

struct ExportSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Text("Used by quick export and by the export widget after recording.")
                .foregroundStyle(.secondary)
            Picker("Format", selection: $prefs.exportFormat) {
                ForEach(Prefs.ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("Frame rate", selection: $prefs.exportFPS) {
                Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
            }
            .fixedSize()
            Picker("Resolution", selection: $prefs.exportResolution) {
                Text("720p").tag(720.0); Text("1080p").tag(1080.0); Text("4K").tag(2160.0)
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("Compression", selection: $prefs.compression) {
                ForEach(Prefs.Compression.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Text(prefs.compression.detail).font(.callout).foregroundStyle(.secondary)
            Divider()
            Row(title: "Show quick export widget after recording",
                detail: "Instead of opening the editor, offer export, copy and edit buttons when a recording ends.") {
                Toggle("", isOn: $prefs.showQuickExportWidget).labelsHidden().toggleStyle(.switch)
            }
        }
        .padding(24)
    }
}

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Text("These work from anywhere on your Mac. Click a shortcut to change it; press Delete to remove it.")
                .foregroundStyle(.secondary)
            ForEach(ShortcutAction.allCases) { a in
                HStack {
                    Label(a.title, systemImage: a.symbol)
                    Spacer()
                    ShortcutField(action: a).frame(width: 140, height: 24)
                }
            }
        }
        .padding(24)
    }
}

struct AdvancedSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Row(title: "Screen super resolution", detail: "Sharpens the screen when zoomed in, using Apple's MetalFX upscaler. Quality is slower to export.") {
                Picker("", selection: $prefs.superResolution) {
                    ForEach(Prefs.SuperResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Row(title: "Variable frame rate export",
                detail: "Only writes frames that change. Much smaller files for recordings with long still stretches.") {
                Toggle("", isOn: $prefs.variableFrameRate).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            Row(title: "Projects folder", detail: displayPath(prefs.saveDirectory)) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([prefs.saveDirectory]) }
            }
        }
        .padding(24)
    }
}
