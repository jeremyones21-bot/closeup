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
    var cameraID: String?         // nil = no camera
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
    private var stream: SCStream?
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
            camera = try CameraRecorder(deviceID: id, to: project.cameraVideo)
        }
        let content = try await Self.content()
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter

        switch opts.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.gone("display") }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
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
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
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
        if opts.systemAudio {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
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
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "unknown") }
        self.writer = writer
        videoIn = video

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if opts.microphoneID != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        if opts.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream

        samples.reserveCapacity(60 * 120)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sampleCursor() }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        try await stream.startCapture()
        camera?.start()
    }

    @MainActor
    func stop() async throws -> ProjectFolder {
        cursorTimer?.invalidate()
        cursorTimer = nil
        try? await stream?.stopCapture()
        stream = nil
        let stopTime = Self.now()
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

        let rows = samples.compactMap { r -> [Double]? in
            let t = r[0] - t0
            return t >= -0.05 ? [((t * 1000).rounded() / 1000), r[1], r[2], r[3]] : nil
        }
        var log = CursorLog(displayWidth: capturedSize.width, displayHeight: capturedSize.height, scale: scale, samples: rows)
        if let first = camera?.firstFrameTime { log.cameraOffset = first - t0 }
        if let d = try? JSONEncoder().encode(log) { try d.write(to: project.cursorFile, options: .atomic) }
        return project
    }

    /// Seconds on the host clock, the same clock ScreenCaptureKit stamps frames with.
    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func sampleCursor() {
        // A recorded window can move; re-read where it is a few times a second.
        tick += 1
        if let id = trackedWindow, tick % 12 == 0, let b = Self.windowBounds(id) {
            region = Self.cocoaRect(fromCG: b)
        }
        let p = NSEvent.mouseLocation
        let f = region
        let x = (p.x - f.minX) / f.width
        let y = (f.maxY - p.y) / f.height
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        let row = [Self.now(), (x * 100_000).rounded() / 100_000, (y * 100_000).rounded() / 100_000, down ? 1 : 0]
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
            if !sessionStarted {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                t0 = sb.presentationTimeStamp.seconds
                sessionStarted = true
            }
            lastFrame = sb
            if let v = videoIn, v.isReadyForMoreMediaData { v.append(sb) }
        case .microphone:
            guard sessionStarted, let a = micIn, a.isReadyForMoreMediaData else { return }
            a.append(sb)
        case .audio:
            guard sessionStarted, let a = systemIn, a.isReadyForMoreMediaData else { return }
            a.append(sb)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }
}
