import AppKit
import AVFoundation
import Foundation

/// closeup-mcp: a Model Context Protocol server (JSON-RPC 2.0 over stdio) so an AI can record,
/// edit and export Closeup videos. Recording goes through the app (it holds the Screen Recording
/// permission) via closeup:// URLs; editing writes the project's edits.json; frames and exports
/// are rendered here with the same compositor the app uses.
@main
struct CloseupMCP {
    @MainActor static func main() async {
        _ = NSApplication.shared   // AppKit (cursor images, fonts) needs an app object
        // Read Closeup's own settings (save folder, auto-zoom, default style), not this tool's.
        UserDefaults.standard.addSuite(named: "com.jeremyjones.closeup")
        let server = Server()
        for await line in StdinLines() {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = await server.handle(msg) { send(reply) }
        }
    }

    static func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }
}

/// Lines from stdin, read off the main thread.
struct StdinLines: AsyncSequence {
    typealias Element = String
    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async -> String? {
            await withCheckedContinuation { c in
                DispatchQueue.global().async { c.resume(returning: readLine(strippingNewline: true)) }
            }
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

struct ToolError: Error { let message: String }

@MainActor
final class Server {
    func handle(_ msg: [String: Any]) async -> [String: Any]? {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }   // notifications need no answer
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            return ok([
                "protocolVersion": (params["protocolVersion"] as? String) ?? "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "closeup", "version": "1.0"],
                "instructions": """
                Closeup records the Mac screen and turns it into a polished video (auto zooms on clicks, smooth \
                cursor, backdrop). Typical flow: start_recording → (the user does the demo) → stop_recording → \
                get_recording to see clicks and zooms → edit (set_trim, add_zoom, remove_zoom, add_cut, \
                add_speed, set_style) → render_frame to check a moment → export. Times are seconds of the \
                original recording.
                """,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Tools.list])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await Tools.call(name, args)
                return ok(["content": content])
            } catch let e as ToolError {
                return ok(["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }
}

@MainActor
enum Tools {
    static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    static let path: [String: Any] = ["type": "string", "description": "Recording folder (.closeup) from list_recordings. Omit for the newest."]
    static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }

    static let list: [[String: Any]] = [
        ["name": "list_recordings", "description": "List Closeup recordings, newest first.",
         "inputSchema": schema(["limit": num("How many (default 20)")])],
        ["name": "start_recording", "description": "Start recording the main display (3-second countdown). Closeup must have Screen Recording permission. Returns once recording has begun.",
         "inputSchema": schema(["camera": bool("Record the webcam too"), "microphone": bool("Record the microphone"), "system_audio": bool("Record the Mac's sound")])],
        ["name": "stop_recording", "description": "Stop the current recording and wait for it to be saved. Returns the new recording's path.",
         "inputSchema": schema([:])],
        ["name": "get_recording", "description": "Details of a recording: duration, size, click times, and its current edits (zooms with ids, trim, cuts, speeds, style).",
         "inputSchema": schema(["path": path])],
        ["name": "set_trim", "description": "Keep only start…end of the recording (seconds). Omit end for the end of the recording.",
         "inputSchema": schema(["path": path, "start": num("Seconds"), "end": num("Seconds")], required: ["start"])],
        ["name": "add_zoom", "description": "Add a zoom from start to end (seconds). By default it follows the cursor; give focus_x/focus_y (0–1, top-left origin) to zoom on a fixed point.",
         "inputSchema": schema(["path": path, "start": num("Seconds"), "end": num("Seconds"), "scale": num("Zoom amount, default 2"),
                                "focus_x": num("0–1 from the left"), "focus_y": num("0–1 from the top"),
                                "instant": bool("Cut straight in, no animation"), "loupe": bool("Magnifying-glass loupe instead of a camera zoom")],
                               required: ["start", "end"])],
        ["name": "update_zoom", "description": "Change a zoom by id (from get_recording). Only the fields given change.",
         "inputSchema": schema(["path": path, "id": str("Zoom id"), "start": num("Seconds"), "end": num("Seconds"), "scale": num("Zoom amount"),
                                "focus_x": num("0–1; pass -1 to follow the cursor again"), "focus_y": num("0–1"), "instant": bool("No animation")],
                               required: ["id"])],
        ["name": "remove_zoom", "description": "Remove a zoom by id, or all zooms with all=true.",
         "inputSchema": schema(["path": path, "id": str("Zoom id"), "all": bool("Remove every zoom")])],
        ["name": "auto_zooms", "description": "Replace the zooms with automatic ones made from the clicks (Screen Studio's rules).",
         "inputSchema": schema(["path": path])],
        ["name": "add_cut", "description": "Cut out start…end (seconds of the recording).",
         "inputSchema": schema(["path": path, "start": num("Seconds"), "end": num("Seconds")], required: ["start", "end"])],
        ["name": "add_speed", "description": "Play start…end faster or slower.",
         "inputSchema": schema(["path": path, "start": num("Seconds"), "end": num("Seconds"), "rate": num("e.g. 2 = twice as fast")], required: ["start", "end", "rate"])],
        ["name": "remove_edit", "description": "Remove a cut or speed change by id, or all of them with all=true.",
         "inputSchema": schema(["path": path, "id": str("Cut or speed id"), "all": bool("Remove every cut and speed change")])],
        ["name": "set_style", "description": "Change the look. Pass any style fields from get_recording (e.g. {\"backdrop\":\"sunset\",\"padding\":0.08,\"corner\":0.02,\"aspect\":\"wide\",\"cursorScale\":1.8,\"motionBlur\":true,\"showCamera\":true}).",
         "inputSchema": schema(["path": path, "style": ["type": "object", "description": "Style fields to change"]], required: ["style"])],
        ["name": "render_frame", "description": "Render one frame of the edited video as an image, to check how a moment looks.",
         "inputSchema": schema(["path": path, "time": num("Seconds of the recording")], required: ["time"])],
        ["name": "export", "description": "Export the edited video. Returns the file path. Can take a while for long recordings.",
         "inputSchema": schema(["path": path, "output": str("Where to save (default: next to the recording, in ~/Movies)"),
                                "resolution": num("Short side: 720, 1080, 1440 or 2160 (default 1080)"),
                                "format": str("mp4 or gif (default mp4)"), "fps": num("Frames per second (default 60)")])],
        ["name": "open_in_editor", "description": "Open a recording in Closeup's editor so the user can see it.",
         "inputSchema": schema(["path": path])],
    ]

    static func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
    static func json(_ o: Any) -> [[String: Any]] {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return text(String(decoding: d, as: UTF8.self))
    }

    static func call(_ name: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "list_recordings":
            let limit = (a["limit"] as? Int) ?? 20
            let iso = ISO8601DateFormatter()
            return json(ProjectFolder.all().prefix(limit).map { ["name": $0.name, "path": $0.url.path, "created": iso.string(from: $0.created)] })

        case "start_recording":
            let before = Set(ProjectFolder.allIncludingUnfinished().map(\.url))
            var q = ["display=1"]
            if let c = a["camera"] as? Bool { q.append("camera=\(c ? 1 : 0)") }
            if let m = a["microphone"] as? Bool { q.append("mic=\(m ? 1 : 0)") }
            if let s = a["system_audio"] as? Bool { q.append("sound=\(s ? 1 : 0)") }
            try openURL("closeup://record?" + q.joined(separator: "&"))
            for _ in 0..<150 {   // countdown is 3 s; allow for the app launching
                try await Task.sleep(for: .milliseconds(100))
                if let new = ProjectFolder.allIncludingUnfinished().first(where: { !before.contains($0.url) }) {
                    return text("Recording started: \(new.url.path). Call stop_recording when done.")
                }
            }
            throw ToolError(message: "Closeup didn't start recording within 15 s. Check that Closeup has Screen Recording permission (System Settings › Privacy & Security) and isn't already recording.")

        case "stop_recording":
            guard let current = ProjectFolder.allIncludingUnfinished().first else { throw ToolError(message: "No recording found.") }
            try openURL("closeup://stop")
            for _ in 0..<600 {
                try await Task.sleep(for: .milliseconds(100))
                if FileManager.default.fileExists(atPath: current.cursorFile.path) {
                    return text("Saved: \(current.url.path)")
                }
            }
            throw ToolError(message: "Closeup didn't finish saving within 60 s.")

        case "get_recording":
            let p = try project(a)
            let (edits, info) = try await load(p)
            var e = try toDict(edits)
            e["zooms"] = e.removeValue(forKey: "segments")
            return json(["path": p.url.path, "name": p.name, "duration": round2(info.duration),
                         "width": info.size.width, "height": info.size.height,
                         "clicks": info.clicks.map(round2),
                         "hasCamera": p.hasCamera, "edits": e])

        case "set_trim":
            let p = try project(a)
            return try await edit(p) { e, info in
                let s = max(0, double(a["start"]) ?? 0)
                let end = double(a["end"]).map { min($0, info.duration) }
                guard (end ?? info.duration) - s > 0.3 else { throw ToolError(message: "The kept part must be longer than 0.3 s.") }
                e.trimStart = s
                e.trimEnd = end.flatMap { $0 >= info.duration - 0.01 ? nil : $0 }
                return "Trimmed to \(s)–\(end ?? info.duration) s."
            }

        case "add_zoom":
            let p = try project(a)
            return try await edit(p) { e, info in
                guard let s = double(a["start"]), let en = double(a["end"]), en > s else { throw ToolError(message: "Give start < end.") }
                var z = ZoomSegment(start: max(0, s), end: min(en, info.duration), scale: double(a["scale"]) ?? 2)
                if a["loupe"] as? Bool == true { z.kind = .loupe; if a["scale"] == nil { z.scale = 2.5 } }
                if let fx = double(a["focus_x"]), let fy = double(a["focus_y"]) { z.focus = CGPoint(x: fx, y: fy) }
                z.instant = a["instant"] as? Bool ?? false
                e.segments.removeAll { $0.start < z.end && $0.end > z.start }
                e.segments.append(z)
                e.segments.sort { $0.start < $1.start }
                return "Added zoom \(z.id.uuidString) at \(z.start)–\(z.end) s, \(z.scale)×. Overlapping zooms were replaced."
            }

        case "update_zoom":
            let p = try project(a)
            return try await edit(p) { e, _ in
                guard let id = (a["id"] as? String).flatMap(UUID.init(uuidString:)), let i = e.segments.firstIndex(where: { $0.id == id })
                else { throw ToolError(message: "No zoom with that id. Use get_recording for ids.") }
                if let v = double(a["start"]) { e.segments[i].start = v }
                if let v = double(a["end"]) { e.segments[i].end = v }
                if let v = double(a["scale"]) { e.segments[i].scale = v }
                if let v = a["instant"] as? Bool { e.segments[i].instant = v }
                if let fx = double(a["focus_x"]) {
                    e.segments[i].focus = fx < 0 ? nil : CGPoint(x: fx, y: double(a["focus_y"]) ?? Double(e.segments[i].focus?.y ?? 0.5))
                }
                return "Updated zoom \(id.uuidString)."
            }

        case "remove_zoom":
            let p = try project(a)
            return try await edit(p) { e, _ in
                if a["all"] as? Bool == true { e.segments = []; return "Removed all zooms." }
                guard let id = (a["id"] as? String).flatMap(UUID.init(uuidString:)), e.segments.contains(where: { $0.id == id })
                else { throw ToolError(message: "No zoom with that id.") }
                e.segments.removeAll { $0.id == id }
                return "Removed zoom \(id.uuidString)."
            }

        case "auto_zooms":
            let p = try project(a)
            return try await edit(p) { e, info in
                e.segments = Motion.autoSegments(samples: info.samples, duration: info.duration)
                return "Made \(e.segments.count) automatic zooms."
            }

        case "add_cut", "add_speed":
            let p = try project(a)
            return try await edit(p) { e, info in
                guard let s = double(a["start"]), let en = double(a["end"]), en > s else { throw ToolError(message: "Give start < end.") }
                if name == "add_cut" {
                    let c = Span(start: max(0, s), end: min(en, info.duration))
                    e.cuts.append(c)
                    return "Cut \(c.start)–\(c.end) s (id \(c.id.uuidString))."
                }
                let r = max(0.1, min(16, double(a["rate"]) ?? 2))
                let sp = Span(start: max(0, s), end: min(en, info.duration), rate: r)
                e.speeds.removeAll { $0.start < sp.end && $0.end > sp.start }
                e.speeds.append(sp)
                return "Speed \(r)× for \(sp.start)–\(sp.end) s (id \(sp.id.uuidString))."
            }

        case "remove_edit":
            let p = try project(a)
            return try await edit(p) { e, _ in
                if a["all"] as? Bool == true { e.cuts = []; e.speeds = []; return "Removed all cuts and speed changes." }
                guard let id = (a["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw ToolError(message: "Give an id.") }
                let n = e.cuts.count + e.speeds.count
                e.cuts.removeAll { $0.id == id }; e.speeds.removeAll { $0.id == id }
                guard e.cuts.count + e.speeds.count < n else { throw ToolError(message: "No cut or speed change with that id.") }
                return "Removed \(id.uuidString)."
            }

        case "set_style":
            let p = try project(a)
            guard let patch = a["style"] as? [String: Any] else { throw ToolError(message: "Give a style object.") }
            return try await edit(p) { e, _ in
                var s = try toDict(e.style)
                let unknown = patch.keys.filter { s[$0] == nil && !optionalStyleKeys.contains($0) }
                guard unknown.isEmpty else {
                    throw ToolError(message: "Unknown style fields: \(unknown.sorted().joined(separator: ", ")). Known: \(s.keys.sorted().joined(separator: ", "))")
                }
                for (k, v) in patch { s[k] = v }
                do { e.style = try fromDict(s, Style.self) } catch {
                    throw ToolError(message: """
                    A style value has the wrong type or isn't one of the allowed choices. Choices: \
                    backdrop: \(Backdrop.allCases.map(\.rawValue).joined(separator: ", ")); \
                    aspect: \(Aspect.allCases.map(\.rawValue).joined(separator: ", ")); \
                    cursorStyle: \(CursorStyle.allCases.map(\.rawValue).joined(separator: ", ")); \
                    cameraCorner: \(CameraCorner.allCases.map(\.rawValue).joined(separator: ", ")); \
                    cameraShape: \(CameraShape.allCases.map(\.rawValue).joined(separator: ", ")); \
                    cameraLook: \(CameraLook.allCases.map(\.rawValue).joined(separator: ", ")); \
                    captionStyle: \(CaptionStyle.allCases.map(\.rawValue).joined(separator: ", ")). Numbers are 0–1 fractions unless named otherwise.
                    """)
                }
                return "Style updated."
            }

        case "render_frame":
            let p = try project(a)
            guard let t = double(a["time"]) else { throw ToolError(message: "Give a time.") }
            let m = try await model(p)
            m.seek(to: t)
            guard let img = await m.currentFrameImage(), let png = scaledPNG(img, maxWidth: 1280)
            else { throw ToolError(message: "Couldn't render that frame.") }
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": "Frame at \(t) s of \(p.name)."]]

        case "export":
            let p = try project(a)
            let m = try await model(p)
            var settings = Exporter.Settings()
            if (a["format"] as? String)?.lowercased() == "gif" { settings.format = .gif }
            if let f = a["fps"] as? Int { settings.fps = max(10, min(60, f)) }
            let res = EditorModel.Resolution(rawValue: double(a["resolution"]) ?? 1080) ?? .p1080
            let ext = settings.format == .gif ? "gif" : "mp4"
            let out = (a["output"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? ProjectFolder.root.appendingPathComponent("\(p.name).\(ext)")
            try? FileManager.default.removeItem(at: out)
            await m.export(resolution: res, settings: settings, to: out)
            if let err = m.exportError { throw ToolError(message: "Export failed: \(err)") }
            return text("Exported \(out.path) (\(Int(m.editedDuration.rounded())) s).")

        case "open_in_editor":
            let p = try project(a)
            var c = URLComponents(string: "closeup://open")!
            c.queryItems = [URLQueryItem(name: "path", value: p.url.path)]
            try openURL(c.url!.absoluteString)
            return text("Opened \(p.name) in Closeup.")

        default:
            throw ToolError(message: "Unknown tool \(name)")
        }
    }

    // MARK: Helpers

    static let optionalStyleKeys: Set<String> = ["imagePath", "cameraCrop"]

    /// Two decimals that serialise cleanly (17.87, not 17.870000000000001).
    static func round2(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", v)) }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func project(_ a: [String: Any]) throws -> ProjectFolder {
        if let s = a["path"] as? String, !s.isEmpty {
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
            let p = ProjectFolder(url: url)
            guard FileManager.default.fileExists(atPath: p.video.path) else { throw ToolError(message: "No recording at \(url.path).") }
            return p
        }
        guard let p = ProjectFolder.all().first else { throw ToolError(message: "There are no recordings yet.") }
        return p
    }

    struct Info { var duration: Double; var size: CGSize; var samples: [CursorSample]; var clicks: [Double] }

    static func load(_ p: ProjectFolder) async throws -> (Edits, Info) {
        let asset = AVURLAsset(url: p.video)
        let duration = try await asset.load(.duration).seconds
        var size = CGSize.zero
        if let t = try await asset.loadTracks(withMediaType: .video).first { size = try await t.load(.naturalSize) }
        let log = p.loadCursor()
        let samples = log?.decoded ?? []
        var wasDown = false
        let clicks = samples.compactMap { s -> Double? in defer { wasDown = s.down }; return s.down && !wasDown ? s.t : nil }
        let edits = p.loadEdits() ?? EditorModel.initialEdits(samples: samples, duration: duration, device: log?.device)
        return (edits, Info(duration: duration, size: size, samples: samples, clicks: clicks))
    }

    static func edit(_ p: ProjectFolder, _ change: (inout Edits, Info) throws -> String) async throws -> [[String: Any]] {
        var (e, info) = try await load(p)
        let msg = try change(&e, info)
        p.save(e)
        return text(msg + " Saved. If the recording is open in Closeup, close and reopen it to see the change.")
    }

    static func model(_ p: ProjectFolder) async throws -> EditorModel {
        if p.loadEdits() == nil { let (e, _) = try await load(p); p.save(e) }
        let m = EditorModel(project: p)
        await m.load()
        if let err = m.loadError { throw ToolError(message: err) }
        return m
    }

    static func toDict<T: Encodable>(_ v: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any] ?? [:]
    }

    static func fromDict<T: Decodable>(_ d: [String: Any], _ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: d))
    }

    static func openURL(_ s: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", s]   // -g: don't bring Closeup to the front
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ToolError(message: "Couldn't reach Closeup (is it installed in /Applications?).") }
    }

    static func scaledPNG(_ img: NSImage, maxWidth: CGFloat) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxWidth / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

extension ProjectFolder {
    /// Like all(), but includes a take still being recorded (no cursor.json yet).
    static func allIncludingUnfinished() -> [ProjectFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "closeup" }.map(ProjectFolder.init(url:)).sorted { $0.created > $1.created }
    }
}
