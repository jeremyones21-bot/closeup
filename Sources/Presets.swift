import AppKit
import Foundation
import UniformTypeIdentifiers

/// A saved look: backdrop, frame, cursor and camera settings.
/// Each preset is one .closeuppreset file (JSON) in Settings › Editing › Save presets in, so a
/// preset can be shared by sending the file, or by pointing that folder at a shared drive.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: Style
    var isDefault = false

    init(name: String, style: Style, isDefault: Bool = false) {
        self.name = name
        self.style = style
        self.isDefault = isDefault
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Preset"
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

enum PresetStore {
    static let fileExtension = "closeuppreset"

    static var folder: URL {
        let dir = UserDefaults.standard.string(forKey: "presetsDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Closeup Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(for p: Preset) -> URL {
        let safe = p.name.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent("\(safe).\(fileExtension)")
    }

    static func all() -> [Preset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }
            .compactMap { try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultPreset() -> Preset? { all().first { $0.isDefault } }

    static func save(_ p: Preset) {
        // One file per name: remove an older file with the same id under a different name.
        for old in all() where old.id == p.id && old.name != p.name { try? FileManager.default.removeItem(at: file(for: old)) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: file(for: p), options: .atomic)
    }

    static func delete(_ p: Preset) { try? FileManager.default.trashItem(at: file(for: p), resultingItemURL: nil) }

    static func setDefault(_ target: Preset?) {
        for var p in all() {
            let should = p.id == target?.id
            if p.isDefault != should { p.isDefault = should; save(p) }
        }
    }

    static func reveal(_ p: Preset) { NSWorkspace.shared.activateFileViewerSelecting([file(for: p)]) }

    /// Copies a preset file someone sent you into the presets folder.
    @MainActor
    static func importFile() -> Preset? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url,
              var p = try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: url)) else { return nil }
        p.id = UUID()
        p.isDefault = false
        save(p)
        return p
    }
}
