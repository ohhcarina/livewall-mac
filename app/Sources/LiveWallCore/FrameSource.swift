// Frame-accurate access to the frames of a source video.
//
// Frames are decoded in one sequential pass over the needed time range and only the requested ones are kept — the
// research prototype reversed the whole tail of the video in ffmpeg, which buffered thousands of frames.
import AVFoundation
import CoreMedia
import Foundation

/// What the source's colour tags say, and whether the engine can convert it faithfully.
public enum SourceColor: Equatable {
    /// BT.709 / sRGB-like SDR (also untagged): handled like the prototype, values read as sRGB and converted to P3.
    case sdrBT709
    /// SDR that is already Display P3: kept as it is, no conversion.
    case displayP3
    /// HDR (PQ / HLG, Dolby Vision 8.4 as iPhones record it): the decoder tone-maps it to SDR BT.709 (the system's own
    /// mapping), from there it goes the `sdrBT709` way. A wallpaper stays SDR: HDR video on the lock screen steps in
    /// brightness at the hand-overs (docs/research-notes.md 一.7). The string says what it is, for the interface.
    case hdr(String)
    /// SDR BT.2020, DCI-P3 ...: no tested conversion, the export is refused instead of coming out wrong.
    case unsupported(String)
}

public final class FrameSource {
    public let url: URL
    public let asset: AVURLAsset
    let track: AVAssetTrack
    /// A small copy of this video (`ProxyMaker`): small decodes come from it, full-size ones from the original. Only
    /// used for requests at most half its width, where its compression is scaled away (11-18), and never for the
    /// measurements the device rules were calibrated on (`frames(fromProxy: false)`).
    public var proxy: FrameSource?
    /// Presentation duration of the video track in seconds.
    public let duration: Double
    /// Frames per second of the source (nominal).
    public let frameRate: Double
    /// Displayed size in pixels (rotation applied).
    public let size: CGSize
    /// Clockwise quarter turns that bring the stored frames upright (portrait phone videos are stored sideways).
    public let quarterTurns: Int
    private let naturalSize: CGSize
    public let sourceColor: SourceColor

    public init(url: URL) async throws {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            throw EngineError.invalid("no video track in \(url.lastPathComponent)")
        }
        track = t
        let range = try await t.load(.timeRange)
        duration = range.duration.seconds
        let fps = try await t.load(.nominalFrameRate)
        frameRate = fps > 0 ? Double(fps) : 30
        let natural = try await t.load(.naturalSize)
        let transform = try await t.load(.preferredTransform)
        if transform.a * transform.d - transform.b * transform.c < 0 {
            throw EngineError.unsupported("镜像（翻转）过的视频暂不支持")
        }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        size = CGSize(width: abs(rect.width), height: abs(rect.height))
        naturalSize = natural
        let degrees = (atan2(Double(transform.b), Double(transform.a)) * 180 / .pi).rounded()
        quarterTurns = ((Int(degrees) / 90) % 4 + 4) % 4
        sourceColor = try await FrameSource.detectColor(of: t)
    }

    private static func detectColor(of track: AVAssetTrack) async throws -> SourceColor {
        guard let format = try await track.load(.formatDescriptions).first else { return .sdrBT709 }
        func tag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
        let hdrTransfers: Set<String> = [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                                         kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String]
        if let transfer, hdrTransfers.contains(transfer) {
            return .hdr(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? "HLG" : "PQ")
        }
        guard let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries) else { return .sdrBT709 }
        let sdr709: Set<String> = [kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, kCMFormatDescriptionColorPrimaries_SMPTE_C as String,
                                   kCMFormatDescriptionColorPrimaries_EBU_3213 as String]
        if sdr709.contains(primaries) { return .sdrBT709 }
        if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) { return .displayP3 }
        return .unsupported("视频的色域是 \(primaries)（不是 BT.709 或 Display P3）")
    }

    private func proxyFor(_ width: Int?) -> FrameSource? {
        guard let proxy, let width, Double(width) * 2 <= Double(proxy.size.width) else { return nil }
        return proxy
    }

    /// Decoder output settings; `width` is the wanted width of the UPRIGHT frame (nil = full resolution).
    private func decoderSettings(width: Int?) -> [String: Any] {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE]
        if case .hdr = sourceColor {
            // asking for SDR BT.709 makes the decoder tone-map (VideoToolbox's HDR → SDR, as AVFoundation shows HDR
            // on an SDR screen); without it the frames are the raw HLG / PQ code values
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                  AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                  AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        if let width {
            let f = Double(width) / Double(size.width)
            settings[kCVPixelBufferWidthKey as String] = max(2, Int((Double(naturalSize.width) * f).rounded()))
            settings[kCVPixelBufferHeightKey as String] = max(2, Int((Double(naturalSize.height) * f).rounded()))
        }
        return settings
    }

    private func upright(_ buffer: CVPixelBuffer) throws -> RGB16Image {
        try RGB16Image(pixelBuffer: buffer).rotated(quarterTurns: quarterTurns)
    }

    /// The frame shown at each time (frame with PTS <= t < PTS + duration; times at or beyond the end give the last
    /// frame). Results are in the order of `times`, decoded to 16-bit RGB with the source's own YCbCr matrix and no
    /// transfer-curve change (HDR sources: tone-mapped to SDR BT.709 first).
    /// `width`: let the decoder scale the frames to this width (previews); nil = full resolution.
    /// `fromProxy: false` for measurements that decide what the phone does (`WindowPlanner.windowFrames`): fine texture
    /// reads lower on the copy (11-18: steps up to 1.7 apart at 544 wide), and those numbers are calibrated on originals.
    public func frames(at times: [Double], width: Int? = nil, fromProxy: Bool = true) async throws -> [RGB16Image] {
        if fromProxy, let proxy = proxyFor(width) { return try await proxy.frames(at: times, width: width) }
        guard let lo = times.min(), let hi = times.max() else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: decoderSettings(width: width))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("cannot read frames from \(url.lastPathComponent)") }
        reader.add(output)
        let margin = 2.0 / frameRate
        let start = max(0, lo - margin)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       end: CMTime(seconds: hi + 4 * margin, preferredTimescale: 60000))
        guard reader.startReading() else { throw EngineError.io("reader failed: \(reader.error?.localizedDescription ?? "?")") }

        // targets sorted by time, remembering their position in `times`
        let order = times.enumerated().sorted { $0.element < $1.element }
        var results = [RGB16Image?](repeating: nil, count: times.count)
        var next = 0                                        // index into `order`
        var previous: (pts: Double, buffer: CVPixelBuffer)?

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // every target before this frame's start is shown by the previous frame
            while next < order.count, let prev = previous, order[next].element < pts {
                results[order[next].offset] = try upright(prev.buffer)
                next += 1
            }
            previous = (pts, pb)
            if next >= order.count { break }
        }
        reader.cancelReading()
        // whatever is left is at or after the last decoded frame
        if next < order.count {
            guard let prev = previous else { throw EngineError.invalid("no frames decoded in the requested range") }
            let image = try upright(prev.buffer)
            while next < order.count { results[order[next].offset] = image; next += 1 }
        }
        return results.map { $0! }
    }

    /// Small frames sampled at `fps` between two times, in order — for planning and for thumbnails. The decoder scales
    /// them to `width` pixels wide; `transform` (e.g. a crop) runs on each as it is decoded, so only its result is kept.
    public func thumbnails(from start: Double, to end: Double, fps: Double, width: Int,
                           transform: (RGB16Image) throws -> RGB16Image = { $0 }) async throws -> [(time: Double, image: RGB16Image)] {
        if let proxy = proxyFor(width) {
            return try await proxy.thumbnails(from: start, to: end, fps: fps, width: width, transform: transform)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: decoderSettings(width: width))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("cannot read frames from \(url.lastPathComponent)") }
        reader.add(output)
        let margin = 2.0 / frameRate
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - margin), preferredTimescale: 60000),
                                       end: CMTime(seconds: min(duration, end + 4 * margin), preferredTimescale: 60000))
        guard reader.startReading() else { throw EngineError.io("reader failed: \(reader.error?.localizedDescription ?? "?")") }
        var out: [(Double, RGB16Image)] = []
        var nextTime = start
        var previous: (pts: Double, buffer: CVPixelBuffer)?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            while let prev = previous, nextTime < pts, nextTime <= end + 1e-9 {
                out.append((nextTime, try transform(try upright(prev.buffer))))
                nextTime += 1 / fps
            }
            previous = (pts, pb)
            if nextTime > end + 1e-9 { break }
        }
        reader.cancelReading()
        if let prev = previous, nextTime <= end + 1e-9 { out.append((nextTime, try transform(try upright(prev.buffer)))) }
        return out
    }
}
