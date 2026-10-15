import Foundation

/// One cursor reading. Position is normalised to the recorded display, origin top-left.
struct CursorSample: Equatable {
    var t: Double
    var x: Double
    var y: Double
    var down: Bool
}

/// cursor.json, written once by the recorder.
struct CursorLog: Codable {
    var displayWidth: Double   // points
    var displayHeight: Double
    var scale: Double          // pixels per point
    var samples: [[Double]]    // [t, x, y, down] — compact, a 10-minute take is ~72k rows
    /// Seconds from the start of screen.mov to the first frame of camera.mov (may be negative).
    var cameraOffset: Double?

    var decoded: [CursorSample] {
        samples.compactMap { r in
            r.count >= 4 ? CursorSample(t: r[0], x: r[1], y: r[2], down: r[3] > 0.5) : nil
        }
    }
}

struct ZoomSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 2.0

    init(start: Double, end: Double, scale: Double = 2.0) {
        self.start = start
        self.end = end
        self.scale = scale
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2.0
    }
}

enum Aspect: String, Codable, CaseIterable, Identifiable {
    case wide, standard, square, tall, source
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wide: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        case .tall: "9:16"
        case .source: "Screen"
        }
    }
    /// width / height, or nil to follow the recording.
    var ratio: Double? {
        switch self {
        case .wide: 16.0 / 9
        case .standard: 4.0 / 3
        case .square: 1
        case .tall: 9.0 / 16
        case .source: nil
        }
    }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded
    var id: String { rawValue }
    var label: String { self == .circle ? "Circle" : "Rounded" }
}

enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case graphite, slate, sand, sky, sage, plum, wallpaper, white, black
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Top and bottom colours as sRGB 0–1.
    var colors: ((Double, Double, Double), (Double, Double, Double)) {
        switch self {
        case .graphite: ((0.20, 0.21, 0.23), (0.11, 0.11, 0.12))
        case .slate: ((0.36, 0.42, 0.50), (0.20, 0.24, 0.30))
        case .sand: ((0.93, 0.90, 0.85), (0.83, 0.79, 0.71))
        case .sky: ((0.64, 0.79, 0.92), (0.36, 0.55, 0.77))
        case .sage: ((0.69, 0.76, 0.66), (0.42, 0.51, 0.41))
        case .plum: ((0.48, 0.36, 0.48), (0.27, 0.19, 0.29))
        case .wallpaper: ((0.2, 0.2, 0.2), (0.1, 0.1, 0.1))
        case .white: ((0.97, 0.97, 0.97), (0.97, 0.97, 0.97))
        case .black: ((0.03, 0.03, 0.03), (0.03, 0.03, 0.03))
        }
    }
}

struct Style: Codable, Equatable {
    var backdrop: Backdrop = .graphite
    var aspect: Aspect = .wide
    var padding: Double = 0.07       // fraction of the canvas's short side
    var corner: Double = 0.012       // fraction of the canvas's short side
    var shadow: Double = 0.5         // 0–1
    var cursorScale: Double = 1.6    // relative to real size
    var cursorSmoothing: Double = 0.5 // 0 = raw, 1 = very smooth
    var clickEffect = true
    var hideIdleCursor = false
    var showCamera = true
    var cameraCorner: CameraCorner = .bottomLeft
    var cameraSize: Double = 0.26      // fraction of the canvas's short side
    var cameraShape: CameraShape = .circle
    var cameraMirror = true

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Style()
        backdrop = try c.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? def.backdrop
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? def.aspect
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? def.padding
        corner = try c.decodeIfPresent(Double.self, forKey: .corner) ?? def.corner
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? def.shadow
        cursorScale = try c.decodeIfPresent(Double.self, forKey: .cursorScale) ?? def.cursorScale
        cursorSmoothing = try c.decodeIfPresent(Double.self, forKey: .cursorSmoothing) ?? def.cursorSmoothing
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? def.clickEffect
        hideIdleCursor = try c.decodeIfPresent(Bool.self, forKey: .hideIdleCursor) ?? def.hideIdleCursor
        showCamera = try c.decodeIfPresent(Bool.self, forKey: .showCamera) ?? def.showCamera
        cameraCorner = try c.decodeIfPresent(CameraCorner.self, forKey: .cameraCorner) ?? def.cameraCorner
        cameraSize = try c.decodeIfPresent(Double.self, forKey: .cameraSize) ?? def.cameraSize
        cameraShape = try c.decodeIfPresent(CameraShape.self, forKey: .cameraShape) ?? def.cameraShape
        cameraMirror = try c.decodeIfPresent(Bool.self, forKey: .cameraMirror) ?? def.cameraMirror
    }
}

/// edits.json: everything the user changes in the editor.
struct Edits: Codable, Equatable {
    var style = Style()
    var segments: [ZoomSegment] = []
    var trimStart: Double = 0
    var trimEnd: Double?   // nil = end of recording

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? []
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
    }
}

/// A recording on disk: ~/Movies/Closeup/<name>.closeup/{screen.mov, cursor.json, edits.json}
struct ProjectFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var video: URL { url.appendingPathComponent("screen.mov") }
    var cameraVideo: URL { url.appendingPathComponent("camera.mov") }
    var hasCamera: Bool { FileManager.default.fileExists(atPath: cameraVideo.path) }
    var cursorFile: URL { url.appendingPathComponent("cursor.json") }
    var editsFile: URL { url.appendingPathComponent("edits.json") }
    var created: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    static let root: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = movies.appendingPathComponent("Closeup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func all() -> [ProjectFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "closeup" }
            .map(ProjectFolder.init(url:))
            .filter { FileManager.default.fileExists(atPath: $0.video.path) }
            .sorted { $0.created > $1.created }
    }

    static func makeNew() -> ProjectFolder {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = root.appendingPathComponent("Recording \(f.string(from: .now)).closeup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ProjectFolder(url: url)
    }

    func loadCursor() -> CursorLog? {
        guard let d = try? Data(contentsOf: cursorFile) else { return nil }
        return try? JSONDecoder().decode(CursorLog.self, from: d)
    }

    func loadEdits() -> Edits? {
        guard let d = try? Data(contentsOf: editsFile) else { return nil }
        return try? JSONDecoder().decode(Edits.self, from: d)
    }

    func save(_ e: Edits) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(e) { try? d.write(to: editsFile, options: .atomic) }
    }
}
