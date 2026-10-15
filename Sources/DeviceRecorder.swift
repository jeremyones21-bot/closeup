import AVFoundation
import CoreMediaIO

/// Records an iPhone or iPad's screen over USB. macOS exposes a connected, trusted device as a
/// capture device once "screen capture devices" are allowed, the same way QuickTime does it.
/// Nothing is installed on the device.
final class DeviceRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "closeup.device")
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private let url: URL
    private let clock: PauseClock
    private(set) var size: CGSize = .zero
    private var started = false

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Lets iOS devices appear as capture devices. Safe to call repeatedly.
    static func enableScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func devices() -> [AVCaptureDevice] {
        enableScreenCaptureDevices()
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    init(deviceID: String, to url: URL, clock: PauseClock) throws {
        self.url = url
        self.clock = clock
        super.init()
        Self.enableScreenCaptureDevices()
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw Failure(message: "That device is no longer connected.") }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure(message: "Couldn't use \(device.localizedName). Unlock it and tap Trust.") }
        session.addInput(input)
        let v = AVCaptureVideoDataOutput()
        v.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        v.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(v) { session.addOutput(v) }
        let a = AVCaptureAudioDataOutput()
        a.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(a) { session.addOutput(a) }
        session.commitConfiguration()
    }

    func start() { queue.async { self.session.startRunning() } }

    /// Returns the recording's first-frame host time, or nil if nothing arrived.
    func stop() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning()
                self.videoIn?.markAsFinished()
                self.audioIn?.markAsFinished()
                c.resume()
            }
        }
        guard let writer, started else { writer?.cancelWriting(); return false }
        await writer.finishWriting()
        return writer.status == .completed
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if clock.isPaused { return }
        // Move capture-clock times onto the host clock, minus any paused time.
        let raw = sb.presentationTimeStamp
        var host = raw
        if let c = session.synchronizationClock { host = CMSyncConvertTime(raw, from: c, to: CMClockGetHostTimeClock()) }
        let shift = clock.offset - CMTimeSubtract(host, raw).seconds   // seconds to subtract from raw times
        let pts = CMTimeSubtract(raw, CMTime(seconds: shift, preferredTimescale: 1_000_000_000))

        if output is AVCaptureVideoDataOutput {
            guard let img = CMSampleBufferGetImageBuffer(sb) else { return }
            if writer == nil {
                let w = CVPixelBufferGetWidth(img), h = CVPixelBufferGetHeight(img)
                size = CGSize(width: w, height: h)
                guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
                let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(10_000_000, w * h * 6)],
                ])
                vin.expectsMediaDataInRealTime = true
                wr.add(vin)
                let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
                ])
                ain.expectsMediaDataInRealTime = true
                wr.add(ain)
                wr.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                guard wr.startWriting() else { return }
                wr.startSession(atSourceTime: pts)
                writer = wr; videoIn = vin; audioIn = ain
                started = true
            }
            guard let vin = videoIn, vin.isReadyForMoreMediaData else { return }
            var t = CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleBufferOut: &copy)
            if let copy { vin.append(copy) }
        } else if started, let ain = audioIn, ain.isReadyForMoreMediaData,
                  let moved = PauseClock.retimed(sb, by: shift) {
            ain.append(moved)
        }
    }
}
