import AppKit
import AVFoundation
import ScreenCaptureKit

/// What to record.
enum CaptureTarget: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// A rectangle on a display, in that display's points, top-left origin.
    case area(CGDirectDisplayID, CGRect)
}

struct CaptureOptions {
    var target: CaptureTarget
    var microphoneID: String?     // nil = no microphone
    var systemAudio = false
    /// Bundle IDs whose sound is recorded; nil = every app.
    var audioApps: [String]?
    var cameraID: String?         // nil = no camera
    var hideDesktopIcons = false
}

/// Shared by the screen, audio, camera and cursor recorders so a pause removes the same span
/// from all of them. All times are host-clock seconds.
final class PauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0.0
    private var pausedAt: Double?

    var isPaused: Bool { lock.withLock { pausedAt != nil } }
    /// Seconds to subtract from a host time to get recording time.
    var offset: Double { lock.withLock { total } }

    func pause(at t: Double) { lock.withLock { if pausedAt == nil { pausedAt = t } } }
    func resume(at t: Double) {
        lock.withLock {
            if let p = pausedAt { total += t - p; pausedAt = nil }
        }
    }
    /// Recording-time "now": frozen while paused.
    func recordingTime(_ t: Double) -> Double {
        lock.withLock { (pausedAt ?? t) - total }
    }

    /// The same sample buffer, moved earlier by the paused time so far.
    static func retimed(_ sb: CMSampleBuffer, by off: Double) -> CMSampleBuffer? {
        guard off > 0 else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        let d = CMTime(seconds: off, preferredTimescale: 1_000_000_000)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, d)
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, d) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }
}

/// Records the screen to screen.mov with the system cursor hidden, and logs the cursor on the
/// side so the editor can redraw it bigger, smoother and with zooms that follow it. Cursor
/// positions are normalised to whatever is being recorded (display, window or area).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case gone(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .gone(let what): "That \(what) is no longer available."
            case .writer(let m): "Couldn't write the recording: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "closeup.recorder")
    let clock = PauseClock()
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var latestFrame: CMSampleBuffer?   // newest frame seen, even while paused
    private var flags: [Double] = []
    private var lastAutosave = 0.0
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var micIn: AVAssetWriterInput?
    private var systemIn: AVAssetWriterInput?
    private var sessionStarted = false
    private var t0: Double = 0
    private var lastFrame: CMSampleBuffer?

    private var cursorTimer: Timer?
    private var samples: [[Double]] = []
    /// Cocoa (bottom-left) global rect of what's being recorded. Updated live for windows.
    private var region: NSRect = .zero
    private var trackedWindow: CGWindowID?
    private var tick = 0
    private var project: ProjectFolder!
    private var capturedSize = CGSize.zero   // points
    private var scale: Double = 2
    private var camera: CameraRecorder?

    var onStreamError: ((Error) -> Void)?

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Global top-left rect (CoreGraphics space) → Cocoa bottom-left rect.
    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return rect
    }

    @MainActor
    func start(_ opts: CaptureOptions, into project: ProjectFolder) async throws {
        self.project = project
        if let id = opts.cameraID {
            camera = try CameraRecorder(deviceID: id, to: project.cameraVideo, clock: clock)
        }
        let content = try await Self.content()
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter

        switch opts.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.gone("display") }
            filter = Self.displayFilter(display, content: content, hideDesktopIcons: opts.hideDesktopIcons)
            capturedSize = CGSize(width: display.width, height: display.height)
            region = Self.screen(for: id)?.frame ?? NSRect(origin: .zero, size: capturedSize)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Failure.gone("window") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            cfg.ignoreShadowsSingleWindow = true
            capturedSize = window.frame.size
            region = Self.cocoaRect(fromCG: Self.windowBounds(id) ?? window.frame)
            trackedWindow = id
        case .area(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.gone("display") }
            filter = Self.displayFilter(display, content: content, hideDesktopIcons: opts.hideDesktopIcons)
            cfg.sourceRect = rect
            capturedSize = rect.size
            let f = Self.screen(for: id)?.frame ?? NSRect(x: 0, y: 0, width: display.width, height: display.height)
            region = NSRect(x: f.minX + rect.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        scale = Double(filter.pointPixelScale)
        let w = Int(capturedSize.width * scale) & ~1
        let h = Int(capturedSize.height * scale) & ~1
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        if let mic = opts.microphoneID {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = mic
        }

        let writer = try AVAssetWriter(outputURL: project.video, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(20_000_000, w * h * 8),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        func audioInput(channels: Int) -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            return a
        }
        if opts.microphoneID != nil { micIn = audioInput(channels: 1) }
        if opts.systemAudio { systemIn = audioInput(channels: 2) }
        // Fragments every 2 s keep screen.mov playable if the app or the Mac dies mid-take.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "unknown") }
        self.writer = writer
        videoIn = video

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if opts.microphoneID != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream

        // Mac sound comes from its own stream so it can be limited to chosen apps without
        // hiding those apps' windows from the video.
        if opts.systemAudio, let display = content.displays.first {
            let apps = opts.audioApps.map { ids in content.applications.filter { ids.contains($0.bundleIdentifier) } }
            let audioFilter = apps.map { SCContentFilter(display: display, including: $0, exceptingWindows: []) }
                ?? SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let acfg = SCStreamConfiguration()
            acfg.capturesAudio = true
            acfg.excludesCurrentProcessAudio = true
            acfg.sampleRate = 48_000
            acfg.channelCount = 2
            acfg.width = 2
            acfg.height = 2
            acfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            acfg.showsCursor = false
            let a = SCStream(filter: audioFilter, configuration: acfg, delegate: self)
            try a.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            audioStream = a
        }

        samples.reserveCapacity(60 * 120)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sampleCursor() }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        try await stream.startCapture()
        try await audioStream?.startCapture()
        camera?.start()
    }

    static func displayFilter(_ display: SCDisplay, content: SCShareableContent, hideDesktopIcons: Bool) -> SCContentFilter {
        let me = Bundle.main.bundleIdentifier
        // Our own windows (bar, notes, status item) and, if asked, Finder's desktop-icon layer.
        let hidden = content.windows.filter { w in
            let owner = w.owningApplication?.bundleIdentifier
            return owner == me || (hideDesktopIcons && owner == "com.apple.finder" && w.windowLayer < 0)
        }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }

    // MARK: Pause, flags

    func pause() {
        clock.pause(at: Self.now())
    }

    func resume() {
        let now = Self.now()
        clock.resume(at: now)
        // Show what's on screen now, not what was there when we paused.
        queue.async { [self] in
            if let f = latestFrame, let v = videoIn, v.isReadyForMoreMediaData {
                var timing = CMSampleTimingInfo(duration: .invalid,
                                                presentationTimeStamp: CMTime(seconds: clock.recordingTime(now), preferredTimescale: 1_000_000_000),
                                                decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: f, sampleTimingEntryCount: 1,
                                                      sampleTimingArray: &timing, sampleBufferOut: &copy)
                if let copy { v.append(copy); lastFrame = copy }
            }
        }
    }

    @MainActor
    func addFlag() {
        flags.append(clock.recordingTime(Self.now()))
    }

    @MainActor
    func stop() async throws -> ProjectFolder {
        cursorTimer?.invalidate()
        cursorTimer = nil
        try? await stream?.stopCapture()
        try? await audioStream?.stopCapture()
        stream = nil
        audioStream = nil
        let stopTime = clock.recordingTime(Self.now())
        await camera?.stop()

        // SCStream only sends frames when something changes. Repeat the last one at the moment
        // we stopped, so a still ending isn't cut off.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let last = lastFrame, let video = videoIn, video.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: .invalid,
                                                    presentationTimeStamp: CMTime(seconds: stopTime, preferredTimescale: 600),
                                                    decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                          sampleTimingArray: &timing, sampleBufferOut: &copy)
                    if let copy, stopTime > t0 { video.append(copy) }
                }
                videoIn?.markAsFinished()
                micIn?.markAsFinished()
                systemIn?.markAsFinished()
                c.resume()
            }
        }
        guard let writer, sessionStarted else {
            writer?.cancelWriting()
            throw Failure.writer("no frames were captured")
        }
        await writer.finishWriting()
        if writer.status == .failed { throw Failure.writer(writer.error?.localizedDescription ?? "unknown") }

        writeLog(to: project.cursorFile)
        try? FileManager.default.removeItem(at: project.partialCursorFile)
        return project
    }

    private func currentLog() -> CursorLog {
        let rows = samples.compactMap { r -> [Double]? in
            let t = r[0] - t0
            return t >= -0.05 ? [((t * 1000).rounded() / 1000), r[1], r[2], r[3]] : nil
        }
        var log = CursorLog(displayWidth: capturedSize.width, displayHeight: capturedSize.height, scale: scale, samples: rows)
        if let first = camera?.firstFrameTime { log.cameraOffset = first - t0 }
        if !flags.isEmpty { log.flags = flags.map { (($0 - t0) * 1000).rounded() / 1000 } }
        return log
    }

    private func writeLog(to url: URL) {
        if let d = try? JSONEncoder().encode(currentLog()) { try? d.write(to: url, options: .atomic) }
    }

    /// Seconds on the host clock, the same clock ScreenCaptureKit stamps frames with.
    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func sampleCursor() {
        if clock.isPaused { return }
        // A recorded window can move; re-read where it is a few times a second.
        tick += 1
        // Autosave the cursor log alongside the fragmented movie, for crash recovery.
        let wall = Self.now()
        if sessionStarted, wall - lastAutosave > 2 {
            lastAutosave = wall
            writeLog(to: project.partialCursorFile)
        }
        if let id = trackedWindow, tick % 12 == 0, let b = Self.windowBounds(id) {
            region = Self.cocoaRect(fromCG: b)
        }
        let p = NSEvent.mouseLocation
        let f = region
        let x = (p.x - f.minX) / f.width
        let y = (f.maxY - p.y) / f.height
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        let row = [clock.recordingTime(wall), (x * 100_000).rounded() / 100_000, (y * 100_000).rounded() / 100_000, down ? 1 : 0]
        // Skip exact repeats unless it's been a while, to keep the file small during idle stretches.
        if let last = samples.last, last[1] == row[1], last[2] == row[2], last[3] == row[3], row[0] - last[0] < 0.25 { return }
        samples.append(row)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            latestFrame = sb
            if clock.isPaused { return }
            guard let sb = PauseClock.retimed(sb, by: clock.offset) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                t0 = sb.presentationTimeStamp.seconds
                sessionStarted = true
            }
            lastFrame = sb
            if let v = videoIn, v.isReadyForMoreMediaData { v.append(sb) }
        case .microphone:
            guard sessionStarted, !clock.isPaused, let a = micIn, a.isReadyForMoreMediaData,
                  let sb = PauseClock.retimed(sb, by: clock.offset) else { return }
            a.append(sb)
        case .audio:
            guard sessionStarted, !clock.isPaused, let a = systemIn, a.isReadyForMoreMediaData,
                  let sb = PauseClock.retimed(sb, by: clock.offset) else { return }
            a.append(sb)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }
}
