import AVFoundation

/// Records a camera to camera.mov. Frame times are converted to the host clock so the editor can
/// line the camera up with the screen recording, which ScreenCaptureKit stamps on the same clock.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "closeup.camera")
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let url: URL
    /// Host-clock seconds of the first written frame.
    private(set) var firstFrameTime: Double?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    init(deviceID: String?, to url: URL) throws {
        self.url = url
        super.init()
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            throw Failure(message: "No camera found.")
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure(message: "Couldn't use \(device.localizedName).") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Failure(message: "Couldn't read from \(device.localizedName).") }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning()
                self.input?.markAsFinished()
                c.resume()
            }
        }
        if let writer, writer.status == .writing { await writer.finishWriting() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sb) else { return }
        var pts = sb.presentationTimeStamp
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        if writer == nil {
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
            ])
            inp.expectsMediaDataInRealTime = true
            wr.add(inp)
            guard wr.startWriting() else { return }
            wr.startSession(atSourceTime: pts)
            writer = wr
            input = inp
            firstFrameTime = pts.seconds
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        if let copy { input.append(copy) }
    }
}
