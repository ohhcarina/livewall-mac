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
    /// A small, lower-frame-rate copy of this video (`ProxyMaker`) for the interface: dragging, playback, filmstrips.
    /// Frames for planning and export never come from it (#0033: it skips frames, and the planner counts frames).
    public var proxy: FrameSource?
    /// Presentation duration of the video track in seconds.
    public let duration: Double
    /// Frames per second of the source (nominal).
    public let frameRate: Double
    /// Displayed size in pixels (rotation applied).
    public let size: CGSize
    /// Clockwise quarter turns that bring the stored frames upright (portrait phone videos are stored sideways).
    public let quarterTurns: Int
    let naturalSize: CGSize
    public let sourceColor: SourceColor
    /// Recently decoded scaled frames (`selectiveFrames`): a plan reads the same frames near the cover several times.
    let frameCache = FrameCache()
    private let layoutLock = NSLock()
    private var cachedLayout: StreamLayout?
    /// Temporal layers and keyframe spacing (`SubsetDecoder`), read once on first use.
    var layout: StreamLayout {
        layoutLock.withLock {
            if let cachedLayout { return cachedLayout }
            let layout = readLayout()
            cachedLayout = layout
            return layout
        }
    }

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

    /// Decoder output settings; `width` is the wanted width of the UPRIGHT frame (nil = full resolution).
    func decoderSettings(width: Int?) -> [String: Any] {
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

    func upright(_ buffer: CVPixelBuffer) throws -> RGB16Image {
        try RGB16Image(pixelBuffer: buffer).rotated(quarterTurns: quarterTurns)
    }

    /// The frame shown at each time (frame with PTS <= t < PTS + duration; times at or beyond the end give the last
    /// frame). Results are in the order of `times`, decoded to 16-bit RGB with the source's own YCbCr matrix and no
    /// transfer-curve change (HDR sources: tone-mapped to SDR BT.709 first).
    /// `width`: let the decoder scale the frames to this width (previews); nil = full resolution.
    public func frames(at times: [Double], width: Int? = nil) async throws -> [RGB16Image] {
        // scaled looks only (the same pixels, `FrameSourceTests`): the export (full size) keeps reading the way it was
        // device-tested
        if let width, let frames = try selectiveFrames(at: times, width: width) { return frames }
        return try await readerFrames(at: times, width: width)
    }

    /// `frames(at:)` decoding every frame from the first time to the last.
    func readerFrames(at times: [Double], width: Int?) async throws -> [RGB16Image] {
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

    /// Most frames `thumbnails` asks `selectiveFrames` for at once (a plan's pool is up to 160: two batches).
    static let selectiveBatch = 96

    /// Small frames sampled at `fps` between two times, in order — for planning and for thumbnails. The decoder scales
    /// them to `width` pixels wide; `transform` (e.g. a crop) runs on each as it is decoded, so only its result is kept.
    /// `exact: false`: a sample may be any frame within about `1 / (2 fps)` s before its time, which lets the decoder
    /// skip the frames in between where the stream allows it (`SubsetDecoder`) — for looks that do not count frames.
    public func thumbnails(from start: Double, to end: Double, fps: Double, width: Int, exact: Bool = true,
                           transform: (RGB16Image) throws -> RGB16Image = { $0 }) async throws -> [(time: Double, image: RGB16Image)] {
        // exact samples: only the frames they depend on, and none decoded again that a recent look already has
        if exact, (end - start) * fps < 480 {
            var times: [Double] = []
            var t = start
            while t <= end + 1e-9 { times.append(t); t += 1 / fps }
            // in batches, made small as they come: a batch's frames are all held at the decode width until it is done
            // (review 11-20: 400 at once, 615 wide for a portrait screen filled from a landscape video, was most of a
            // gigabyte)
            var out: [(time: Double, image: RGB16Image)] = []
            for first in stride(from: 0, to: times.count, by: Self.selectiveBatch) {
                let batch = Array(times[first..<min(times.count, first + Self.selectiveBatch)])
                guard let frames = try selectiveFrames(at: batch, width: width) else { out = []; break }
                out += try zip(batch, frames).map { ($0, try transform($1)) }
            }
            if out.count == times.count { return out }
        }
        if !exact, let subset = cheapSubset(forRate: 2 * fps) {
            var out: [(Double, RGB16Image)] = []
            var nextTime = start
            var previous: CVPixelBuffer?
            try decode(subset, from: start, to: end, width: width) { pts, pb in
                while let prev = previous, nextTime < pts, nextTime <= end + 1e-9 {
                    out.append((nextTime, try transform(try upright(prev))))
                    nextTime += 1 / fps
                }
                previous = pb
                return nextTime <= end + 1e-9
            }
            if let prev = previous, nextTime <= end + 1e-9 { out.append((nextTime, try transform(try upright(prev)))) }
            return out
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
