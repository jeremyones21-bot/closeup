import AVFoundation
import AudioToolbox

/// Audio processing done on this Mac: voice cleanup, the click sound, and generated voiceover.
enum AudioTools {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: Click sound

    /// A short, soft tick, generated once into Application Support.
    static func clickSoundURL() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Closeup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("click.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 48_000.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * 0.06)),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return nil }
        buf.frameLength = buf.frameCapacity
        let data = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / rate
            // A damped 2.4 kHz + 900 Hz blip: reads as a mouse click, not a beep.
            let env = exp(-t * 90)
            data[i] = Float(env * (0.45 * sin(2 * .pi * 2400 * t) + 0.35 * sin(2 * .pi * 900 * t)))
        }
        try? file.write(from: buf)
        return url
    }

    // MARK: Voice cleanup

    /// Renders the microphone through Apple's voice isolation (and, for Podcast, an EQ, a
    /// compressor and a limiter) into voice-<mode>.m4a in the project.
    static func processVoice(_ project: ProjectFolder, mode: VoiceMode) async throws {
        guard let name = mode.fileName else { return }
        let out = project.url.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return }

        // 1. Microphone track → PCM file the engine can read.
        let raw = project.url.appendingPathComponent("voice-raw.caf")
        try await extractFirstAudio(project.video, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }

        // 2. Offline render through the chain.
        let input = try AVAudioFile(forReading: raw)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        var chain: [AVAudioNode] = []
        let isolation = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: fourCC("vois"),
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        chain.append(isolation)
        if mode == .podcast {
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 80; eq.bands[0].bypass = false
            eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 250; eq.bands[1].gain = -2; eq.bands[1].bandwidth = 1; eq.bands[1].bypass = false
            eq.bands[2].filterType = .parametric; eq.bands[2].frequency = 3500; eq.bands[2].gain = 3; eq.bands[2].bandwidth = 1.2; eq.bands[2].bypass = false
            chain.append(eq)
            let comp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 6, 0)
            chain.append(comp)
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            chain.append(limiter)
        }
        chain.forEach { engine.attach($0) }
        var prev: AVAudioNode = player
        for n in chain { engine.connect(prev, to: n, format: format); prev = n }
        engine.connect(prev, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()

        let tmp = project.url.appendingPathComponent("voice-tmp.caf")
        try? FileManager.default.removeItem(at: tmp)
        let output = try AVAudioFile(forWriting: tmp, settings: engine.manualRenderingFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < input.length {
            let left = AVAudioFrameCount(input.length - engine.manualRenderingSampleTime)
            let status = try engine.renderOffline(min(buffer.frameCapacity, left), to: buffer)
            if status == .success { try output.write(from: buffer) } else if status == .error { break }
        }
        player.stop()
        engine.stop()

        // 3. Compress to AAC.
        let asset = AVURLAsset(url: tmp)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure(message: "Couldn't encode the cleaned voice.") }
        try await ex.export(to: out, as: .m4a)
        try? FileManager.default.removeItem(at: tmp)
    }

    static func extractFirstAudio(_ url: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure(message: "This recording has no microphone audio.") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(o)
        reader.startReading()
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else { return }
        try? FileManager.default.removeItem(at: out)
        let file = try AVAudioFile(forWriting: out, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while let sb = o.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { continue }
            buf.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
            try file.write(from: buf)
        }
    }

    private static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    // MARK: Voiceover (Kokoro, on this Mac)

    static let voices = ["af_heart", "af_bella", "af_nicole", "am_michael", "am_fenrir", "bf_emma", "bm_george"]

    static var kokoroAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "\(home)/.hyperframes-venv/bin/python")
            && FileManager.default.fileExists(atPath: "\(home)/.cache/hyperframes/tts/models/kokoro-v1.0.onnx")
    }

    /// Speaks `text` with the locally installed Kokoro model into the project; returns the file name.
    static func generateVoiceover(_ text: String, voice: String, speed: Double = 1, in project: ProjectFolder) async throws -> String {
        guard kokoroAvailable else { throw Failure(message: "The Kokoro voice model isn't installed on this Mac.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = "voiceover-\(UUID().uuidString.prefix(8)).wav"
        let out = project.url.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(home)/.hyperframes-venv/bin/python")
        p.arguments = ["\(home)/.cache/hyperframes/tts/synth-v3.py",
                       "\(home)/.cache/hyperframes/tts/models/kokoro-v1.0.onnx",
                       "\(home)/.cache/hyperframes/tts/voices/voices-v1.0.bin",
                       text, voice, String(speed), out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: "Voice generation failed. \(msg.suffix(200))")
        }
        return name
    }
}
