import AVFoundation
import Speech
import Vision

/// On-device analysis of a recording. Results are cached in the project folder:
/// faces.json (camera face positions), silences.json (quiet stretches of the microphone),
/// captions.json (transcript, word by word). Nothing is sent anywhere.
enum Analyzer {
    @MainActor
    static func run(for model: EditorModel) async {
        let project = model.project
        let offset = project.loadCursor()?.cameraOffset ?? 0
        async let faces = project.hasCamera ? cachedFaces(project, offset: offset) : []
        async let silences = cachedSilences(project)
        let (f, s) = await (faces, silences)
        model.analysis.faces = f
        model.analysis.silences = s
        model.refreshScene()
    }

    // MARK: Faces

    static func cachedFaces(_ p: ProjectFolder, offset: Double) async -> [FaceSample] {
        let file = p.url.appendingPathComponent("faces.json")
        if let d = try? Data(contentsOf: file), let f = try? JSONDecoder().decode([FaceSample].self, from: d) { return f }
        let faces = await detectFaces(p.cameraVideo, offset: offset)
        try? JSONEncoder().encode(faces).write(to: file)
        return faces
    }

    /// Four looks a second at the camera; positions are smoothed so the framing doesn't jitter.
    static func detectFaces(_ url: URL, offset: Double) async -> [FaceSample] {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var out: [FaceSample] = []
        var sx = Spring(0.5), sy = Spring(0.45), ss = Spring(0.3)
        var t = 0.0
        while t < dur {
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                let req = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: cg).perform([req])
                if let face = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                    let b = face.boundingBox   // normalised, bottom-left origin
                    let x = sx.step(to: b.midX, time: 0.5, dt: 0.25)
                    let y = sy.step(to: 1 - b.midY, time: 0.5, dt: 0.25)
                    let s = ss.step(to: b.height, time: 0.8, dt: 0.25)
                    out.append(FaceSample(t: t + offset, x: x, y: y, size: s))
                }
            }
            t += 0.25
        }
        return out
    }

    // MARK: Silence

    static func cachedSilences(_ p: ProjectFolder) async -> [Span] {
        let file = p.url.appendingPathComponent("silences.json")
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Span].self, from: d) { return s }
        let s = await detectSilences(p.video)
        try? JSONEncoder().encode(s).write(to: file)
        return s
    }

    /// Quiet stretches (≥ 0.8 s) in the first audio track (the microphone when there is one).
    static func detectSilences(_ url: URL) async -> [Span] {
        let levels = await audioLevels(url, window: 0.05)
        guard !levels.isEmpty else { return [] }
        // Threshold relative to the recording: well below its typical speaking level.
        let sorted = levels.sorted()
        let loud = sorted[Int(Double(sorted.count) * 0.9)]
        let threshold = max(0.004, loud * 0.12)
        var spans: [Span] = []
        var start: Double?
        for (i, l) in levels.enumerated() {
            let t = Double(i) * 0.05
            if l < threshold { if start == nil { start = t } }
            else if let s = start { if t - s >= 0.8 { spans.append(Span(start: s, end: t)) }; start = nil }
        }
        if let s = start, Double(levels.count) * 0.05 - s >= 0.8 { spans.append(Span(start: s, end: Double(levels.count) * 0.05)) }
        return spans
    }

    /// RMS level per `window` seconds of the first audio track.
    static func audioLevels(_ url: URL, window: Double) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ])
        reader.add(out)
        guard reader.startReading() else { return [] }
        let per = Int(16_000 * window)
        var levels: [Float] = []
        var acc: Float = 0, n = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let ptr else { continue }
            let samples = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: len / 4)
            for i in 0..<(len / 4) {
                acc += samples[i] * samples[i]
                n += 1
                if n == per { levels.append(sqrt(acc / Float(n))); acc = 0; n = 0 }
            }
        }
        return levels
    }

    // MARK: Transcription

    enum TranscriptionError: LocalizedError {
        case notAllowed, noAudio, unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Closeup needs Speech Recognition permission (System Settings › Privacy & Security › Speech Recognition)."
            case .noAudio: "This recording has no microphone audio to transcribe."
            case .unavailable: "On-device speech recognition isn't available for your language on this Mac."
            case .failed(let m): "Transcription failed: \(m)"
            }
        }
    }

    /// Transcribes the microphone on device and groups words into caption lines.
    static func transcribe(_ p: ProjectFolder) async throws -> [Caption] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw TranscriptionError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.unavailable }

        // The recognizer wants an audio file: pull the microphone track out as m4a.
        let asset = AVURLAsset(url: p.video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptionError.noAudio }
        let comp = AVMutableComposition()
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try at.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        let audioURL = p.url.appendingPathComponent("voice.m4a")
        try? FileManager.default.removeItem(at: audioURL)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw TranscriptionError.noAudio }
        try await ex.export(to: audioURL, as: .m4a)

        let req = SFSpeechURLRecognitionRequest(url: audioURL)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: TranscriptionError.failed(error.localizedDescription)); return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.segments) }
            }
        }
        let words = segments.map { Caption.Word(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring) }
        let captions = group(words)
        p.saveCaptions(captions)
        return captions
    }

    /// Lines of up to ~7 words / 3 s, broken at pauses.
    static func group(_ words: [Caption.Word]) -> [Caption] {
        var lines: [Caption] = []
        var cur: [Caption.Word] = []
        for w in words {
            if let last = cur.last, cur.count >= 7 || w.start - last.end > 0.6 || w.end - (cur.first?.start ?? w.start) > 3 {
                lines.append(Caption(start: cur.first!.start, end: max(last.end, cur.first!.start + 0.8), words: cur))
                cur = []
            }
            cur.append(w)
        }
        if let first = cur.first, let last = cur.last { lines.append(Caption(start: first.start, end: max(last.end, first.start + 0.8), words: cur)) }
        // Hold each line until the next starts (up to 0.8 s) so captions don't flicker off between lines.
        for i in lines.indices.dropLast() { lines[i].end = min(max(lines[i].end, lines[i].end), min(lines[i + 1].start, lines[i].end + 0.8)) }
        return lines
    }

    static let fillers: Set<String> = ["um", "uh", "erm", "er", "ah", "hmm", "mm", "uhm", "umm"]
}

extension ProjectFolder {
    var captionsFile: URL { url.appendingPathComponent("captions.json") }

    func loadCaptions() -> [Caption] {
        guard let d = try? Data(contentsOf: captionsFile) else { return [] }
        return (try? JSONDecoder().decode([Caption].self, from: d)) ?? []
    }

    func saveCaptions(_ c: [Caption]) {
        try? JSONEncoder().encode(c).write(to: captionsFile, options: .atomic)
    }

    /// Subtitles for the edited video: times moved onto the output timeline, cut words dropped.
    func srt(_ captions: [Caption], timeline: EditTimeline) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = ""
        var n = 1
        for c in captions {
            let words = c.words.filter { !timeline.isCut(($0.start + $0.end) / 2) }
            guard let first = words.first, let last = words.last else { continue }
            let a = timeline.output(at: first.start), b = timeline.output(at: max(last.end, c.end))
            guard b > a else { continue }
            out += "\(n)\n\(ts(a)) --> \(ts(b))\n\(words.map(\.text).joined(separator: " "))\n\n"
            n += 1
        }
        return out
    }
}
