import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records one display to screen.mov with the system cursor hidden, and logs the cursor on the
/// side so the editor can redraw it bigger, smoother and with zooms that follow it.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay, writer(String)
        var errorDescription: String? {
            switch self {
            case .noDisplay: "That display is no longer available."
            case .writer(let m): "Couldn't write the recording: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "closeup.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var sessionStarted = false
    private var t0: Double = 0
    private var lastFrame: CMSampleBuffer?

    private var cursorTimer: Timer?
    private var samples: [[Double]] = []
    private var screenFrame: NSRect = .zero   // Cocoa coordinates of the recorded display
    private var project: ProjectFolder!
    private var displaySize = CGSize.zero
    private var scale: Double = 2

    var onStreamError: ((Error) -> Void)?

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    @MainActor
    func start(displayID: CGDirectDisplayID, microphone: Bool, into project: ProjectFolder) async throws {
        self.project = project
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        scale = Double(filter.pointPixelScale)
        displaySize = CGSize(width: display.width, height: display.height)
        let w = Int(Double(display.width) * scale) & ~1
        let h = Int(Double(display.height) * scale) & ~1
        screenFrame = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.frame ?? NSRect(origin: .zero, size: displaySize)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        if microphone { cfg.captureMicrophone = true }

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
        if microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioIn = audio
        }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "unknown") }
        self.writer = writer
        videoIn = video

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream

        samples.reserveCapacity(60 * 120)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sampleCursor() }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        try await stream.startCapture()
    }

    @MainActor
    func stop() async throws -> ProjectFolder {
        cursorTimer?.invalidate()
        cursorTimer = nil
        try? await stream?.stopCapture()
        stream = nil
        let stopTime = Self.now()

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
                audioIn?.markAsFinished()
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
        let log = CursorLog(displayWidth: displaySize.width, displayHeight: displaySize.height, scale: scale, samples: rows)
        if let d = try? JSONEncoder().encode(log) { try d.write(to: project.cursorFile, options: .atomic) }
        return project
    }

    /// Seconds on the host clock, the same clock ScreenCaptureKit stamps frames with.
    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func sampleCursor() {
        let p = NSEvent.mouseLocation
        let f = screenFrame
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
            guard sessionStarted, let a = audioIn, a.isReadyForMoreMediaData else { return }
            a.append(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }
}
