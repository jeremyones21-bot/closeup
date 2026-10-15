import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Renders a composition to MP4 (H.264 / HEVC at a chosen bitrate) or GIF.
/// Unlike AVAssetExportSession this controls compression and frame rate, mixes every audio
/// track (microphone + Mac sound) into one, and can skip unchanged frames.
enum Exporter {
    struct Settings {
        var format: Prefs.ExportFormat = .mp4
        var fps: Int = 60
        var compression: Prefs.Compression = .social
        var hevc = false
        var variableFrameRate = false
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func export(asset: AVAsset, composition: AVVideoComposition, range: CMTimeRange, settings: Settings,
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let vout = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        vout.videoComposition = composition
        vout.alwaysCopiesSampleData = false
        reader.add(vout)

        if settings.format == .gif {
            try await gif(reader: reader, video: vout, size: composition.renderSize, fps: settings.fps, range: range, to: url, progress: progress)
            return
        }

        var aout: AVAssetReaderAudioMixOutput?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let a = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(a)
            aout = a
        }

        let size = composition.renderSize
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = size.width * size.height * Double(settings.fps)
        let bitrate = Int(pixels * settings.compression.bitsPerPixel * (settings.hevc ? 0.6 : 1))
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, bitrate),
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
            ],
        ])
        vin.expectsMediaDataInRealTime = false
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            ain = a
        }

        guard reader.startReading() else { throw Failure(message: reader.error?.localizedDescription ?? "Couldn't read the recording.") }
        guard writer.startWriting() else { throw Failure(message: writer.error?.localizedDescription ?? "Couldn't write the file.") }
        writer.startSession(atSourceTime: range.start)

        let total = max(range.duration.seconds, 0.001)
        let vq = DispatchQueue(label: "closeup.export.video"), aq = DispatchQueue(label: "closeup.export.audio")
        let skipper = settings.variableFrameRate ? FrameSkipper() : nil

        async let videoDone: Void = withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var last: CMSampleBuffer?
            var skippedLast = false
            vin.requestMediaDataWhenReady(on: vq) {
                while vin.isReadyForMoreMediaData {
                    guard let sb = vout.copyNextSampleBuffer() else {
                        // A skipped final frame still needs writing, or the video ends early.
                        if skippedLast, let last { vin.append(last) }
                        vin.markAsFinished()
                        c.resume()
                        return
                    }
                    if let skipper, let img = CMSampleBufferGetImageBuffer(sb), skipper.isRepeat(img) {
                        last = sb
                        skippedLast = true
                        continue
                    }
                    skippedLast = false
                    last = sb
                    vin.append(sb)
                    progress(min(0.999, (sb.presentationTimeStamp - range.start).seconds / total))
                }
            }
        }
        let audioIn = ain, audioOut = aout
        async let audioDone: Void = withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            guard let ain = audioIn, let aout = audioOut else { c.resume(); return }
            ain.requestMediaDataWhenReady(on: aq) {
                while ain.isReadyForMoreMediaData {
                    guard let sb = aout.copyNextSampleBuffer() else {
                        ain.markAsFinished()
                        c.resume()
                        return
                    }
                    ain.append(sb)
                }
            }
        }
        _ = await (videoDone, audioDone)

        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure(message: reader.error?.localizedDescription ?? "Reading failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw Failure(message: writer.error?.localizedDescription ?? "Writing failed.") }
        progress(1)
    }

    private static func gif(reader: AVAssetReader, video: AVAssetReaderVideoCompositionOutput, size: CGSize, fps: Int,
                            range: CMTimeRange, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, Int.max, nil) else {
            throw Failure(message: "Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        guard reader.startReading() else { throw Failure(message: reader.error?.localizedDescription ?? "Couldn't read the recording.") }
        let ctx = CIContext()
        let delay = 1.0 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        let total = max(range.duration.seconds, 0.001)
        while let sb = video.copyNextSampleBuffer() {
            guard let img = CMSampleBufferGetImageBuffer(sb),
                  let cg = ctx.createCGImage(CIImage(cvPixelBuffer: img), from: CGRect(origin: .zero, size: size)) else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress(min(0.999, (sb.presentationTimeStamp - range.start).seconds / total))
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "Couldn't finish the GIF.") }
        progress(1)
    }
}

/// Detects frames identical to the previous one by comparing a dense grid of pixels.
private final class FrameSkipper: @unchecked Sendable {
    private var previous: [UInt32] = []

    func isRepeat(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        // Every 3rd pixel of every 3rd row: dense enough to catch a cursor or a typed letter.
        var sample: [UInt32] = []
        sample.reserveCapacity((w / 3 + 1) * (h / 3 + 1))
        for y in stride(from: 0, to: h, by: 3) {
            let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt32.self)
            for x in stride(from: 0, to: w, by: 3) { sample.append(p[x]) }
        }
        defer { previous = sample }
        return sample == previous
    }
}
