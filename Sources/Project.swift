import Foundation

/// One cursor reading. Position is normalised to the recorded display, origin top-left.
struct CursorSample: Equatable {
    var t: Double
    var x: Double
    var y: Double
    var down: Bool
}

struct ShortcutPress: Codable, Equatable {
    var t: Double
    var label: String
}

/// cursor.json, written once by the recorder.
struct CursorLog: Codable {
    var displayWidth: Double   // points
    var displayHeight: Double
    var scale: Double          // pixels per point
    var samples: [[Double]]    // [t, x, y, down] — compact, a 10-minute take is ~72k rows
    /// Seconds from the start of screen.mov to the first frame of camera.mov (may be negative).
    var cameraOffset: Double?
    /// Moments marked while recording (seconds into screen.mov).
    var flags: [Double]?
    /// Set for iPhone / iPad recordings: the device's name, used to draw a device frame.
    var device: String?
    /// When keys were pressed (no key names), for speeding up typing. Needs Accessibility.
    var keys: [Double]?
    /// Shortcuts pressed (only combinations with ⌘, ⌃ or ⌥), as [time, label].
    var shortcuts: [ShortcutPress]?

    var decoded: [CursorSample] {
        samples.compactMap { r in
            r.count >= 4 ? CursorSample(t: r[0], x: r[1], y: r[2], down: r[3] > 0.5) : nil
        }
    }
}

struct ZoomSegment: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case classic, loupe
        var id: String { rawValue }
        var label: String { self == .classic ? "Classic" : "Loupe" }
    }

    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 2.0
    var kind: Kind = .classic
    /// Fixed point to zoom on (0–1 of the recording). nil = follow the cursor.
    var focus: CGPoint?
    /// Cut straight in instead of easing.
    var instant = false

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
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .classic
        focus = try c.decodeIfPresent(CGPoint.self, forKey: .focus)
        instant = try c.decodeIfPresent(Bool.self, forKey: .instant) ?? false
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

enum CameraLook: String, Codable, CaseIterable, Identifiable {
    case natural, warm, cool, vivid, mono, film
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case bold, subtle, highlight, karaoke
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bold: "Bold"
        case .subtle: "Subtle"
        case .highlight: "Box"
        case .karaoke: "Word by word"
        }
    }
}

enum CursorStyle: String, Codable, CaseIterable, Identifiable {
    case arrow, dot, ring
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case graphite, slate, sand, sky, sage, plum, dusk, mint, peach, ocean, wallpaper, image, white, black
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
        case .dusk: ((0.42, 0.40, 0.62), (0.86, 0.55, 0.48))
        case .mint: ((0.80, 0.93, 0.87), (0.55, 0.78, 0.72))
        case .peach: ((0.99, 0.86, 0.76), (0.93, 0.66, 0.60))
        case .ocean: ((0.18, 0.42, 0.62), (0.06, 0.16, 0.30))
        case .wallpaper, .image: ((0.2, 0.2, 0.2), (0.1, 0.1, 0.1))
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
    var cursorStyle: CursorStyle = .arrow
    var clickRipple = true
    var clickSound = false
    var motionBlur = true
    var loopCursor = false
    var shadowAngle: Double = 90        // degrees; 90 = straight down
    var shadowDistance: Double = 0.012  // fraction of the canvas's short side
    var shadowSoftness: Double = 0.03
    var inset: Double = 0               // frame width around the recording, fraction of short side
    var insetDark = false
    /// Backdrop image: a macOS wallpaper path, or a file copied into the project.
    var imagePath: String?
    var cameraCrop: CGRect?             // part of the camera to show, 0–1
    var cameraLook: CameraLook = .natural
    var cameraSharpen: Double = 0
    var hideCameraInSilence = false
    var cameraCutout = false
    var faceTracking = false
    var captions = false
    var captionStyle: CaptionStyle = .bold
    var showShortcuts = false

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
        cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? def.cursorStyle
        clickRipple = try c.decodeIfPresent(Bool.self, forKey: .clickRipple) ?? def.clickRipple
        clickSound = try c.decodeIfPresent(Bool.self, forKey: .clickSound) ?? def.clickSound
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? def.motionBlur
        loopCursor = try c.decodeIfPresent(Bool.self, forKey: .loopCursor) ?? def.loopCursor
        shadowAngle = try c.decodeIfPresent(Double.self, forKey: .shadowAngle) ?? def.shadowAngle
        shadowDistance = try c.decodeIfPresent(Double.self, forKey: .shadowDistance) ?? def.shadowDistance
        shadowSoftness = try c.decodeIfPresent(Double.self, forKey: .shadowSoftness) ?? def.shadowSoftness
        inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? def.inset
        insetDark = try c.decodeIfPresent(Bool.self, forKey: .insetDark) ?? def.insetDark
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        cameraCrop = try c.decodeIfPresent(CGRect.self, forKey: .cameraCrop)
        cameraLook = try c.decodeIfPresent(CameraLook.self, forKey: .cameraLook) ?? def.cameraLook
        cameraSharpen = try c.decodeIfPresent(Double.self, forKey: .cameraSharpen) ?? def.cameraSharpen
        hideCameraInSilence = try c.decodeIfPresent(Bool.self, forKey: .hideCameraInSilence) ?? def.hideCameraInSilence
        cameraCutout = try c.decodeIfPresent(Bool.self, forKey: .cameraCutout) ?? def.cameraCutout
        faceTracking = try c.decodeIfPresent(Bool.self, forKey: .faceTracking) ?? def.faceTracking
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? def.captions
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle) ?? def.captionStyle
        showShortcuts = try c.decodeIfPresent(Bool.self, forKey: .showShortcuts) ?? def.showShortcuts
    }
}

/// A stretch of the recording, in recording time, with whatever a track needs to know about it.
struct Span: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    /// Speed track: playback rate (2 = twice as fast).
    var rate: Double = 1
    /// Mask / highlight / zoom focus: a rectangle in the recording, 0–1, top-left origin.
    var rect: CGRect?
    var kind: MaskKind = .blur
    var layout: CameraLayout = .overlay

    init(start: Double, end: Double, rate: Double = 1, rect: CGRect? = nil, kind: MaskKind = .blur, layout: CameraLayout = .overlay) {
        self.start = start
        self.end = end
        self.rate = rate
        self.rect = rect
        self.kind = kind
        self.layout = layout
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        rect = try c.decodeIfPresent(CGRect.self, forKey: .rect)
        kind = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? .blur
        layout = try c.decodeIfPresent(CameraLayout.self, forKey: .layout) ?? .overlay
    }
}

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case blur, pixelate, matched, highlight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .matched: "Match surroundings"
        case .highlight: "Highlight"
        }
    }
}

enum CameraLayout: String, Codable, CaseIterable, Identifiable {
    case overlay, fullscreen, split, screenOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overlay: "Camera overlay"
        case .fullscreen: "Fullscreen camera"
        case .split: "Split screen"
        case .screenOnly: "Screen only"
        }
    }
}

/// edits.json: everything the user changes in the editor. All times are recording times.
struct Edits: Codable, Equatable {
    var style = Style()
    var segments: [ZoomSegment] = []
    var trimStart: Double = 0
    var trimEnd: Double?   // nil = end of recording
    var cuts: [Span] = []
    var speeds: [Span] = []
    var cursorHidden: [Span] = []
    var masks: [Span] = []
    var layouts: [Span] = []
    /// Part of the recording to keep, 0–1, top-left origin. nil = all of it.
    var crop: CGRect?
    var volume: Double = 1
    var musicVolume: Double = 0.25
    var voiceMode: VoiceMode = .standard
    /// Background music file name inside the project folder.
    var musicFile: String?
    var voiceovers: [Voiceover] = []

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? []
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        cuts = try c.decodeIfPresent([Span].self, forKey: .cuts) ?? []
        speeds = try c.decodeIfPresent([Span].self, forKey: .speeds) ?? []
        cursorHidden = try c.decodeIfPresent([Span].self, forKey: .cursorHidden) ?? []
        masks = try c.decodeIfPresent([Span].self, forKey: .masks) ?? []
        layouts = try c.decodeIfPresent([Span].self, forKey: .layouts) ?? []
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.25
        voiceMode = try c.decodeIfPresent(VoiceMode.self, forKey: .voiceMode) ?? .standard
        musicFile = try c.decodeIfPresent(String.self, forKey: .musicFile)
        voiceovers = try c.decodeIfPresent([Voiceover].self, forKey: .voiceovers) ?? []
    }
}

enum VoiceMode: String, Codable, CaseIterable, Identifiable {
    case standard, clean, podcast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Standard"
        case .clean: "Noise reduction"
        case .podcast: "Podcast"
        }
    }
    var detail: String {
        switch self {
        case .standard: "Your microphone as it was."
        case .clean: "Fans, keyboards and the room turned down; your voice kept."
        case .podcast: "Noise reduction plus levelling and presence, for narration-led videos."
        }
    }
    var fileName: String? { self == .standard ? nil : "voice-\(rawValue).m4a" }
}

/// Narration generated from text, placed at a recording time.
struct Voiceover: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var text: String
    var voice: String
    var file: String
}

/// A recording on disk: ~/Movies/Closeup/<name>.closeup/{screen.mov, cursor.json, edits.json}
struct ProjectFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// screen.mov from a recording, or screen.<ext> for an imported video.
    var video: URL {
        let mov = url.appendingPathComponent("screen.mov")
        if FileManager.default.fileExists(atPath: mov.path) { return mov }
        for ext in ["mp4", "m4v", "mov"] {
            let u = url.appendingPathComponent("screen.\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return mov
    }
    var versionsFolder: URL { url.appendingPathComponent("versions", isDirectory: true) }
    var cameraVideo: URL { url.appendingPathComponent("camera.mov") }
    var hasCamera: Bool { FileManager.default.fileExists(atPath: cameraVideo.path) }
    var cursorFile: URL { url.appendingPathComponent("cursor.json") }
    /// Written every 2 s during recording; becomes cursor.json if the take is recovered.
    var partialCursorFile: URL { url.appendingPathComponent("cursor.partial.json") }
    var editsFile: URL { url.appendingPathComponent("edits.json") }
    var created: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Settings › Recording › Save new projects to (default ~/Movies/Closeup).
    static var root: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = UserDefaults.standard.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? movies.appendingPathComponent("Closeup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func all() -> [ProjectFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "closeup" }
            .map(ProjectFolder.init(url:))
            .filter { FileManager.default.fileExists(atPath: $0.video.path) }
            .sorted { $0.created > $1.created }
    }

    static func makeNew(name: String? = nil) -> ProjectFolder {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = root.appendingPathComponent("\(name ?? "Recording \(f.string(from: .now))").closeup", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(name ?? "Recording") \(n).closeup", isDirectory: true)
            n += 1
        }
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

    /// Saves the edits. Before overwriting, the previous version is kept in versions/ (at most one
    /// a minute, the last 40), so an earlier state can be restored.
    func save(_ e: Edits) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(e) else { return }
        let fm = FileManager.default
        if let old = try? Data(contentsOf: editsFile), old != d {
            try? fm.createDirectory(at: versionsFolder, withIntermediateDirectories: true)
            let existing = ((try? fm.contentsOfDirectory(at: versionsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let lastDate = existing.last.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate } ?? .distantPast
            if Date().timeIntervalSince(lastDate) > 60 {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                try? old.write(to: versionsFolder.appendingPathComponent("edits \(f.string(from: .now)).json"))
                for extra in existing.dropLast(39) { try? fm.removeItem(at: extra) }
            }
        }
        try? d.write(to: editsFile, options: .atomic)
    }
}
