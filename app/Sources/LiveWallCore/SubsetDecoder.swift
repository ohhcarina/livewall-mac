// Decoding only the frames a sparse look needs (#0033, 11-18).
//
// `AVAssetReader` decodes every frame of the range it reads. A 240 fps 4K Mac aerial is 158 401 frames for 11 minutes,
// so reading it end to end took 294 s even when one frame in a hundred was wanted. Two cheap subsets exist:
// - HEVC temporal layers: the Mac aerials (like iPhone slow motion) are coded in 5 layers, 15 / 30 / 60 / 120 / 240 fps
//   cumulative, each referencing only itself and lower ones, so layers 0...k decode on their own (measured on 俯瞰伦敦:
//   layer 0 in 7.5 s, layers 0–1 in 14.8 s, all of it in 139.7 s);
// - sync frames, for streams without layers whose keyframes come often enough.
// Only SDR sources go this way: HDR needs the tone mapping `AVAssetReader` asks the decoder for (`decoderSettings`).
import AVFoundation
import CoreMedia
import VideoToolbox

/// Which samples of the stream get decoded.
enum DecodeSubset: Equatable {
    /// HEVC temporal id <= n.
    case temporalLayers(Int)
    /// Sync (key) frames only.
    case syncOnly
}

/// What the first seconds of the stream say about cheap subsets.
struct StreamLayout {
    /// Frames per second of temporal layers 0...k, cumulative (HEVC with more than one layer; empty otherwise).
    var layerRates: [Double] = []
    /// Longest gap between sync frames seen (nil: fewer than two seen).
    var maxSyncGap: Double?
    /// Length prefix of each NAL unit in a sample, 0 when slice headers cannot be read.
    var nalLengthSize = 0
    /// HEVC (temporal ids, sub-layer non-reference types) or H.264 (nal_ref_idc); nil for other codecs.
    var hevc: Bool?
}

/// What a sample's first coded slice says.
struct SliceInfo {
    /// HEVC temporal id (0 for H.264).
    var tid: Int
    /// No picture of the same or a lower temporal layer refers to it (HEVC `_N` types, H.264 nal_ref_idc 0).
    var unreferenced: Bool
    /// Nothing after it in decode order refers to anything before it (HEVC IDR / BLA, H.264 IDR). A CRA or an H.264
    /// I frame is a sync frame too, but the leading pictures after it may refer to the group before.
    var closed: Bool
}

extension FrameSource {
    static let layoutLook = 12.0

    /// Reads the first `layoutLook` seconds without decoding (sample headers only).
    func readLayout() -> StreamLayout {
        var layout = StreamLayout()
        guard let reader = try? AVAssetReader(asset: asset) else { return layout }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return layout }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(duration, Self.layoutLook), preferredTimescale: 600))
        guard reader.startReading() else { return layout }
        defer { reader.cancelReading() }
        var counts: [Int: Int] = [:]
        var syncs: [Double] = []
        var first = Double.infinity, last = -Double.infinity
        var nalSize: Int?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            first = min(first, pts); last = max(last, pts)
            if Self.isSync(sample) { syncs.append(pts) }
            if nalSize == nil {
                let found = Self.nalLengthSize(sample)
                nalSize = found?.size ?? 0
                layout.hevc = found?.hevc
                layout.nalLengthSize = nalSize ?? 0
            }
            if layout.hevc == true, let info = Self.sliceInfo(sample, layout) { counts[info.tid, default: 0] += 1 }
        }
        let span = last - first + 1 / max(1, frameRate)
        if let top = counts.keys.max(), top > 0, span > 1 {
            var total = 0
            layout.layerRates = (0...top).map { total += counts[$0] ?? 0; return Double(total) / span }
        }
        syncs.sort()
        if syncs.count >= 2 {
            layout.maxSyncGap = zip(syncs, syncs.dropFirst()).map { $1 - $0 }.max()
        }
        return layout
    }

    /// The cheapest subset whose frames are at most `1 / rate` s apart, or nil (decode everything the usual way).
    func cheapSubset(forRate rate: Double) -> DecodeSubset? {
        switch sourceColor {
        case .sdrBT709, .displayP3: break
        default: return nil
        }
        let layout = layout
        if let k = layout.layerRates.firstIndex(where: { $0 >= rate }), k < layout.layerRates.count - 1 {
            return .temporalLayers(k)
        }
        // only when keyframes are much rarer than frames, or there is nothing to save
        if let gap = layout.maxSyncGap, gap <= 1 / rate, gap * frameRate >= 4 { return .syncOnly }
        return nil
    }

    /// Decodes the `subset` frames whose presentation time can matter for `start ... end` and hands them to `body` in
    /// presentation order, scaled like `decoderSettings(width:)` (`pixelFormat` overrides its format). `body` returns
    /// false to stop. Frames come from the sync frame before `start` on, so the first may be earlier than `start`.
    func decode(_ subset: DecodeSubset, from start: Double, to end: Double, width: Int?,
                pixelFormat: OSType? = nil, storedSize: (width: Int, height: Int)? = nil,
                body: (Double, CVPixelBuffer) throws -> Bool) throws {
        let layout = layout
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("cannot read frames from \(url.lastPathComponent)") }
        reader.add(output)
        let from = syncTime(atOrBefore: start)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60000),
                                       end: CMTime(seconds: min(duration, end + 4 / frameRate), preferredTimescale: 60000))
        guard reader.startReading() else { throw EngineError.io("reader failed: \(reader.error?.localizedDescription ?? "?")") }
        defer { reader.cancelReading() }

        var attributes = decoderSettings(width: width)
        attributes.removeValue(forKey: AVVideoColorPropertiesKey)       // SDR only: nothing to convert
        if let pixelFormat { attributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat }
        if let storedSize {                 // as stored (before rotation), e.g. the editing copy's own size
            attributes[kCVPixelBufferWidthKey as String] = storedSize.width
            attributes[kCVPixelBufferHeightKey as String] = storedSize.height
        }
        let box = DecodedBox()
        var session: VTDecompressionSession?
        defer {
            if let session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
            }
        }
        var started = false, stopped = false
        var fedSinceWait = 0
        var lastDTS = -Double.infinity

        // hands over every frame that no later sample can come before (its DTS <= its PTS)
        func flush(upTo limit: Double) throws {
            guard let session else { return }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            fedSinceWait = 0
            for frame in box.take(before: limit) where !stopped {
                if try !body(frame.pts, frame.buffer) { stopped = true }
            }
        }

        while !stopped, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let sync = Self.isSync(sample)
            if !started { guard sync else { continue }; started = true }
            switch subset {
            case .syncOnly where !sync: continue
            case .temporalLayers(let k):
                guard let tid = Self.sliceInfo(sample, layout)?.tid, tid <= k else { continue }
            default: break
            }
            if session == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample) else { continue }
                let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                          imageBufferAttributes: attributes as CFDictionary,
                                                          outputCallback: nil, decompressionSessionOut: &session)
                guard status == noErr, session != nil else { throw EngineError.io("decoder failed (\(status))") }
            }
            let dts = CMSampleBufferGetDecodeTimeStamp(sample)
            lastDTS = dts.isValid ? dts.seconds : CMSampleBufferGetPresentationTimeStamp(sample).seconds
            VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                                              infoFlagsOut: nil) { status, _, image, pts, _ in
                if status == noErr, let image { box.add(pts.seconds, image) }
            }
            fedSinceWait += 1
            if fedSinceWait >= 16 {
                try flush(upTo: lastDTS)
                if box.newest > end + 4 / frameRate { break }
            }
        }
        if !stopped { try flush(upTo: .infinity) }
    }

    /// The frames shown at `times` (as `frames(at:)`), decoding only what they depend on: from the sync frame before
    /// each, and of an HEVC stream with temporal layers only the layers up to the highest one wanted after that point.
    /// Frames far apart (the 11 picks of a plan) then cost a few hundred decodes each instead of every frame between
    /// them. Nil when this cannot be done (HDR, a frame that did not decode, an open-GOP frame that needs the previous
    /// group): the caller decodes the usual way.
    func selectiveFrames(at times: [Double], width: Int) throws -> [RGB16Image]? {
        switch sourceColor {
        case .sdrBT709, .displayP3: break
        default: return nil
        }
        guard let lo = times.min(), let hi = times.max() else { return [] }
        let layout = layout
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        let margin = 2.0 / frameRate
        let from = syncTime(atOrBefore: max(0, lo - margin))
        // past the last time by more than a hierarchical group: a frame there may reference an anchor shown up to 15
        // frames later (5 temporal layers, the Mac aerials), and without it the batch falls back to decoding everything
        // (review 11-20). Compressed samples only; nothing past the last wanted one is decoded.
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60000),
                                       end: CMTime(seconds: min(duration, hi + 16 * margin), preferredTimescale: 60000))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        // the compressed samples, in decode order, from the first sync frame on
        var samples: [(buffer: CMSampleBuffer, pts: Double, tid: Int, unreferenced: Bool, closed: Bool)] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let sync = Self.isSync(sample)
            if samples.isEmpty && !sync { continue }
            let info = Self.sliceInfo(sample, layout)
            // other codecs: every sync frame counts as closed (no slice headers to read)
            samples.append((sample, CMSampleBufferGetPresentationTimeStamp(sample).seconds, info?.tid ?? 0,
                            info?.unreferenced ?? false, sync && (info?.closed ?? true)))
        }
        guard !samples.isEmpty else { return nil }

        // which sample each time shows: the latest presentation time at or before it (else the last frame)
        let byPTS = samples.indices.sorted { samples[$0].pts < samples[$1].pts }
        let ptsSorted = byPTS.map { samples[$0].pts }
        let shown: [Int] = times.map { t in
            var lo = 0, hi = ptsSorted.count            // first index with pts > t
            while lo < hi { let m = (lo + hi) / 2; if ptsSorted[m] <= t { lo = m + 1 } else { hi = m } }
            return byPTS[max(0, lo - 1)]
        }
        var cached: [Int: RGB16Image] = [:]
        for i in Set(shown) { if let image = frameCache.image(pts: samples[i].pts, width: width) { cached[i] = image } }
        let targets = Set(shown).subtracting(cached.keys)

        // walking back in decode order: a sample is needed when it is wanted, or when a wanted frame later in its group
        // is on a higher temporal layer, or on the same one and this sample can be referenced from its own layer (each
        // layer references only itself and lower ones; without layers every id reads as 0)
        var needed = [Bool](repeating: false, count: samples.count)
        var want = -1
        for i in samples.indices.reversed() {
            let wanted = targets.contains(i)
            if wanted { want = max(want, samples[i].tid) }
            needed[i] = wanted || samples[i].tid < want || (samples[i].tid == want && !samples[i].unreferenced)
            if samples[i].closed { want = -1 }      // an open group's leading pictures may need the one before
        }

        var attributes = decoderSettings(width: width)
        attributes.removeValue(forKey: AVVideoColorPropertiesKey)
        let box = DecodedBox()
        var session: VTDecompressionSession?
        defer { if let session { VTDecompressionSessionInvalidate(session) } }
        let lastNeeded = targets.max() ?? 0
        for i in samples.indices where needed[i] {
            guard i <= lastNeeded else { break }
            try Task.checkCancellation()
            guard let format = CMSampleBufferGetFormatDescription(samples[i].buffer) else { return nil }
            if session == nil {
                guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                   imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &session) == noErr, session != nil else { return nil }
            } else if !VTDecompressionSessionCanAcceptFormatDescription(session!, formatDescription: format) {
                return nil
            }
            let keep = targets.contains(i)
            VTDecompressionSessionDecodeFrame(session!, sampleBuffer: samples[i].buffer, flags: [._EnableAsynchronousDecompression],
                                              infoFlagsOut: nil) { status, _, image, pts, _ in
                if keep, status == noErr, let image { box.add(pts.seconds, image) }
            }
        }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        let decoded = box.take(before: .infinity)
        var images = cached
        for i in targets {
            guard let frame = decoded.first(where: { $0.pts == samples[i].pts }) else { return nil }
            let image = try upright(frame.buffer)
            images[i] = image
            frameCache.insert(image, pts: samples[i].pts, width: width)
        }
        return shown.map { images[$0]! }
    }

    /// Presentation time of the sync frame at or before `t` (0 when it cannot be told).
    func syncTime(atOrBefore t: Double) -> Double {
        guard t > 0, let cursor = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 60000)) else { return 0 }
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { return 0 }
        }
        return max(0, min(t, cursor.presentationTimeStamp.seconds))
    }

    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// NAL length prefix of an HEVC or H.264 stream, nil for other codecs.
    static func nalLengthSize(_ sample: CMSampleBuffer) -> (size: Int, hevc: Bool)? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let hevc: Set<FourCharCode> = [kCMVideoCodecType_HEVC, FourCharCode(0x6865_7631) /* hev1 */,
                                       FourCharCode(0x6476_6831) /* dvh1 */, FourCharCode(0x6476_6865) /* dvhe */]
        let h264: Set<FourCharCode> = [kCMVideoCodecType_H264, FourCharCode(0x6176_6333) /* avc3 */]
        let codec = CMFormatDescriptionGetMediaSubType(format)
        var size: Int32 = 0
        if hevc.contains(codec) {
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                     parameterSetSizeOut: nil, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: &size) == noErr, size > 0 else { return nil }
            return (Int(size), true)
        }
        if h264.contains(codec) {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                     parameterSetSizeOut: nil, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: &size) == noErr, size > 0 else { return nil }
            return (Int(size), false)
        }
        return nil
    }

    /// The sample's first coded slice NAL unit, read from its header.
    static func sliceInfo(_ sample: CMSampleBuffer, _ layout: StreamLayout) -> SliceInfo? {
        let n = layout.nalLengthSize
        guard n > 0, let hevc = layout.hevc, let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var offset = 0
        var header = [UInt8](repeating: 0, count: n + 2)
        while offset + n + 2 <= length {
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: n + 2, destination: &header) == noErr else { return nil }
            var size = 0
            for i in 0..<n { size = size << 8 | Int(header[i]) }
            if hevc {
                let type = Int(header[n] >> 1) & 0x3f
                // VCL types 0...31; even ones below 16 are sub-layer non-reference (TRAIL_N, TSA_N, STSA_N, RADL_N, RASL_N)
                if type < 32 {
                    return SliceInfo(tid: Int(header[n + 1] & 7) - 1, unreferenced: type < 16 && type % 2 == 0,
                                     closed: (16...20).contains(type))
                }
            } else {
                let type = Int(header[n] & 0x1f)
                if type == 1 || type == 5 { return SliceInfo(tid: 0, unreferenced: (header[n] >> 5) & 3 == 0, closed: type == 5) }
            }
            guard size > 0 else { return nil }
            offset += n + size
        }
        return nil
    }
}

/// Scaled upright frames by presentation time and decode width, oldest dropped first past `limit` bytes.
final class FrameCache: @unchecked Sendable {
    static let limit = 192 << 20
    private let lock = NSLock()
    private var images: [Key: RGB16Image] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private struct Key: Hashable { var pts: Double; var width: Int }

    func image(pts: Double, width: Int) -> RGB16Image? {
        lock.withLock { images[Key(pts: pts, width: width)] }
    }

    func insert(_ image: RGB16Image, pts: Double, width: Int) {
        lock.withLock {
            let key = Key(pts: pts, width: width)
            guard images[key] == nil else { return }
            images[key] = image
            order.append(key)
            bytes += image.pixels.count * 2
            while bytes > Self.limit, !order.isEmpty {
                let old = order.removeFirst()
                if let gone = images.removeValue(forKey: old) { bytes -= gone.pixels.count * 2 }
            }
        }
    }
}

/// Frames the decoder hands back (on its own thread), kept until they can be given out in presentation order.
private final class DecodedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(pts: Double, buffer: CVPixelBuffer)] = []
    private(set) var newest = -Double.infinity

    func add(_ pts: Double, _ buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        frames.append((pts, buffer))
    }

    /// The frames before `limit`, in presentation order.
    func take(before limit: Double) -> [(pts: Double, buffer: CVPixelBuffer)] {
        lock.lock(); defer { lock.unlock() }
        frames.sort { $0.pts < $1.pts }
        let cut = frames.firstIndex { $0.pts >= limit } ?? frames.count
        let out = Array(frames[..<cut])
        frames.removeFirst(cut)
        if let last = out.last { newest = max(newest, last.pts) }
        return out
    }
}
