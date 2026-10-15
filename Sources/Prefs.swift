import Foundation
import Observation
import ServiceManagement

/// App-wide settings (the Settings window). Each one is stored in UserDefaults as it changes.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum AfterRecording: String, CaseIterable, Identifiable {
        case openProject, exportCopy, exportSave
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openProject: "Create project"
            case .exportCopy: "Export and copy to clipboard"
            case .exportSave: "Export and save to file"
            }
        }
    }

    enum CameraResolution: String, CaseIterable, Identifiable {
        case p720, p1080, p2160
        var id: String { rawValue }
        var label: String { self == .p720 ? "720p" : self == .p1080 ? "1080p" : "4K" }
    }

    enum ExportFormat: String, CaseIterable, Identifiable { case mp4, gif; var id: String { rawValue }; var label: String { rawValue.uppercased() } }

    enum Compression: String, CaseIterable, Identifiable {
        case studio, social, web, webLow
        var id: String { rawValue }
        var label: String {
            switch self {
            case .studio: "Studio"
            case .social: "Social Media"
            case .web: "Web"
            case .webLow: "Web (Low)"
            }
        }
        var detail: String {
            switch self {
            case .studio: "Highest quality. Large files, for editing elsewhere or archiving."
            case .social: "Good for social media. Compression is noticeable on a close look, and sites may compress it again."
            case .web: "Small files for websites and docs."
            case .webLow: "Smallest files. Visible compression."
            }
        }
        /// Bits per pixel per frame for H.264; HEVC uses about 60% of this.
        var bitsPerPixel: Double {
            switch self {
            case .studio: 0.30
            case .social: 0.12
            case .web: 0.07
            case .webLow: 0.04
            }
        }
    }

    enum SuperResolution: String, CaseIterable, Identifiable {
        case off, fast, quality
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    // General
    var startAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if startAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                startAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    var hideDockIconWhenIdle: Bool { didSet { d.set(hideDockIconWhenIdle, forKey: "hideDockIconWhenIdle") } }

    // Recording
    var saveDirectory: URL { didSet { d.set(saveDirectory.path, forKey: "saveDirectory") } }
    var highlightRecordedArea: Bool { didSet { d.set(highlightRecordedArea, forKey: "highlightRecordedArea") } }
    var autoZooms: Bool { didSet { d.set(autoZooms, forKey: "autoZooms") } }
    var showRecordingWidget: Bool { didSet { d.set(showRecordingWidget, forKey: "showRecordingWidget") } }
    var cameraResolution: CameraResolution { didSet { d.set(cameraResolution.rawValue, forKey: "cameraResolution") } }
    var afterRecording: AfterRecording { didSet { d.set(afterRecording.rawValue, forKey: "afterRecording") } }

    // Editing
    var useLastProjectSettings: Bool { didSet { d.set(useLastProjectSettings, forKey: "useLastProjectSettings") } }
    var lastStyle: Style? {
        didSet { d.set(lastStyle.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastStyle") }
    }
    var presetsDirectory: URL { didSet { d.set(presetsDirectory.path, forKey: "presetsDirectory") } }

    // Quick export
    var exportFormat: ExportFormat { didSet { d.set(exportFormat.rawValue, forKey: "exportFormat") } }
    var exportFPS: Int { didSet { d.set(exportFPS, forKey: "exportFPS") } }
    var exportResolution: Double { didSet { d.set(exportResolution, forKey: "exportResolution") } }
    var compression: Compression { didSet { d.set(compression.rawValue, forKey: "compression") } }
    var showQuickExportWidget: Bool { didSet { d.set(showQuickExportWidget, forKey: "showQuickExportWidget") } }

    // Experimental
    var superResolution: SuperResolution { didSet { d.set(superResolution.rawValue, forKey: "superResolution") } }
    var variableFrameRate: Bool { didSet { d.set(variableFrameRate, forKey: "variableFrameRate") } }

    private init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        hideDockIconWhenIdle = d.bool(forKey: "hideDockIconWhenIdle")
        saveDirectory = d.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? movies.appendingPathComponent("Closeup", isDirectory: true)
        highlightRecordedArea = d.object(forKey: "highlightRecordedArea") as? Bool ?? true
        autoZooms = d.object(forKey: "autoZooms") as? Bool ?? true
        showRecordingWidget = d.object(forKey: "showRecordingWidget") as? Bool ?? true
        cameraResolution = CameraResolution(rawValue: d.string(forKey: "cameraResolution") ?? "") ?? .p1080
        afterRecording = AfterRecording(rawValue: d.string(forKey: "afterRecording") ?? "") ?? .openProject
        useLastProjectSettings = d.bool(forKey: "useLastProjectSettings")
        lastStyle = d.data(forKey: "lastStyle").flatMap { try? JSONDecoder().decode(Style.self, from: $0) }
        presetsDirectory = d.string(forKey: "presetsDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? docs.appendingPathComponent("Closeup Presets", isDirectory: true)
        exportFormat = ExportFormat(rawValue: d.string(forKey: "exportFormat") ?? "") ?? .mp4
        exportFPS = d.object(forKey: "exportFPS") as? Int ?? 60
        exportResolution = d.object(forKey: "exportResolution") as? Double ?? 1080
        compression = Compression(rawValue: d.string(forKey: "compression") ?? "") ?? .social
        showQuickExportWidget = d.object(forKey: "showQuickExportWidget") as? Bool ?? false
        superResolution = SuperResolution(rawValue: d.string(forKey: "superResolution") ?? "") ?? .off
        variableFrameRate = d.bool(forKey: "variableFrameRate")
    }

    func reset() {
        for key in ["hideDockIconWhenIdle", "saveDirectory", "highlightRecordedArea", "autoZooms", "showRecordingWidget",
                    "cameraResolution", "afterRecording", "useLastProjectSettings", "lastStyle", "presetsDirectory",
                    "exportFormat", "exportFPS", "exportResolution", "compression", "showQuickExportWidget",
                    "superResolution", "variableFrameRate", "countdown", "hideDesktopIcons", "hideDockIcon"] {
            d.removeObject(forKey: key)
        }
        for a in ShortcutAction.allCases {
            d.removeObject(forKey: "shortcut.\(a.rawValue)")
            d.removeObject(forKey: "shortcut.\(a.rawValue).cleared")
        }
    }
}
