// A small copy of the source for editing (11-18, the user: 「先做 final cut pro 中那种代理……最后导出的时候再渲染」):
// scrubbing, filmstrips, the lock-screen preview and the planner's small samples decode it instead of the 4K original;
// the export and every full-size measurement still read the original (`FrameSource.proxy`).
//
// Same frames at the same presentation times (sample buffers are passed through with their timestamps), same rotation
// and colour tags, so a frame number means the same picture in both. HDR is tone-mapped to SDR BT.709 on the way, the
// same mapping `FrameSource` asks the decoder for, so the copy's frames match what the planner sees in the original.
import AVFoundation
import CoreMedia
import Foundation

public enum ProxyMaker {
    /// Long side of the copy. Planner samples are at most a few hundred pixels wide; the video view rarely shows the
    /// picture larger than this.
    public static let longSide = 1280
    /// A keyframe every this many frames: any frame decodes after at most this many others (scrubbing).
    public static let keyFrameInterval = 10
    /// Bump when the copy's recipe changes (size, keyframes, quality, colour handling): cached copies are keyed on it.
    public static let version = 1

    /// Whether decoding the original is slow enough to be worth a copy: larger than 1080p, or a codec without a cheap
    /// hardware path everywhere (AV1, VP9, ProRes ...).
    public static func isWorthIt(_ source: FrameSource) async -> Bool {
        if max(source.size.width, source.size.height) > 1920 { return true }
        guard let format = try? await source.track.load(.formatDescriptions).first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        // H.264 / HEVC in their usual sample-entry names, Dolby Vision on HEVC as iPhones record it
        let cheap: Set<FourCharCode> = [kCMVideoCodecType_H264, FourCharCode(0x6176_6333) /* avc3 */,
                                        kCMVideoCodecType_HEVC, FourCharCode(0x6865_7631) /* hev1 */,
                                        FourCharCode(0x6476_6831) /* dvh1 */, FourCharCode(0x6476_6865) /* dvhe */]
        return !cheap.contains(codec)
    }

    /// Writes the copy to `url` (replaced if it exists). `progress` gets 0...1 as frames are written.
    public static func make(from source: FrameSource, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try? FileManager.default.removeItem(at: url)
        let track = source.track
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let scale = min(1, Double(longSide) / Double(max(natural.width, natural.height)))
        let w = max(2, Int((Double(natural.width) * scale / 2).rounded()) * 2)
        let h = max(2, Int((Double(natural.height) * scale / 2).rounded()) * 2)

        // colour: the source's own tags (no conversion), or SDR BT.709 for HDR (the decoder tone-maps)
        var colour: [String: Any]?
        if case .hdr = source.sourceColor {
            colour = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        } else if let format = try await track.load(.formatDescriptions).first {
            // each tag the source has, on its own: a partly tagged source must read the same way from the copy
            func tag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
            var tags: [String: Any] = [:]
            if let p = tag(kCMFormatDescriptionExtension_ColorPrimaries) { tags[AVVideoColorPrimariesKey] = p }
            if let t = tag(kCMFormatDescriptionExtension_TransferFunction) { tags[AVVideoTransferFunctionKey] = t }
            if let m = tag(kCMFormatDescriptionExtension_YCbCrMatrix) { tags[AVVideoYCbCrMatrixKey] = m }
            // AVAssetWriterInput wants all three or none: fill a missing one with BT.709, which is how an untagged
            // part reads anyway (`FrameSource.detectColor`), rather than drop the ones the source does have
            if !tags.isEmpty {
                tags[AVVideoColorPrimariesKey] = tags[AVVideoColorPrimariesKey] ?? AVVideoColorPrimaries_ITU_R_709_2
                tags[AVVideoTransferFunctionKey] = tags[AVVideoTransferFunctionKey] ?? AVVideoTransferFunction_ITU_R_709_2
                tags[AVVideoYCbCrMatrixKey] = tags[AVVideoYCbCrMatrixKey] ?? AVVideoYCbCrMatrix_ITU_R_709_2
                colour = tags
            }
        }

        let reader = try AVAssetReader(asset: source.asset)
        var readSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h]
        if case .hdr = source.sourceColor { readSettings[AVVideoColorPropertiesKey] = colour }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("cannot read \(source.url.lastPathComponent)") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var writeSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8, AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                                              AVVideoAllowFrameReorderingKey: false] as [String: Any],
        ]
        if let colour { writeSettings[AVVideoColorPropertiesKey] = colour }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: writeSettings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.unsupported("cannot write the editing copy") }
        writer.add(input)

        guard reader.startReading() else { throw EngineError.io("reader failed: \(reader.error?.localizedDescription ?? "?")") }
        guard writer.startWriting() else { throw EngineError.io("writer failed: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        var reported = -1.0
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard input.append(sample) else {
                    throw EngineError.io("writing the editing copy failed: \(writer.error?.localizedDescription ?? "?")")
                }
                let done = min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / max(0.001, source.duration))
                if done - reported >= 0.01 { reported = done; progress(done) }        // whole percents, not every frame
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw EngineError.io("reading the original failed: \(reader.error?.localizedDescription ?? "?")")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw EngineError.io("writing the editing copy failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }
}
