// A small copy of the source for editing (11-18, the user: 「先做 final cut pro 中那种代理……最后导出的时候再渲染」):
// dragging, playback and filmstrips use it instead of the 4K original. Planning, the lock-screen preview, the export and
// the exact frame shown when paused all read the original.
//
// At most `maxFrameRate` (#0033, 11-18): an 11-minute 240 fps aerial copied frame by frame took 320 s and 4.6 GB; a
// stream with temporal layers gives its 30 fps frames without decoding the rest (layers 0–1 of 俯瞰伦敦: 14.8 s against
// 139.7 s). Kept frames keep their presentation times, rotation and colour tags, so a time means the same picture in
// both wherever the copy has that frame. HDR is tone-mapped to SDR BT.709 on the way, as `FrameSource` asks for.
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Lets the editing copy wait while the person works (#0033, 11-19): the media engine decodes one stream at full speed,
/// two at once each at half, so a drag or the first look at a new cover must not share it with the copy.
public final class DecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false

    public init() {}

    /// While true, `pass` waits.
    public var isHeld: Bool {
        get { condition.lock(); defer { condition.unlock() }; return held }
        set { condition.lock(); held = newValue; condition.broadcast(); condition.unlock() }
    }

    /// Returns once the gate is open (or `cancelled` says so). Blocks the calling thread: call it from the copy's own
    /// decoding thread only, never from a Swift concurrency task (it would hold one of the pool's few threads).
    func pass(cancelled: () -> Bool) {
        condition.lock()
        defer { condition.unlock() }
        while held, !cancelled() { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1)) }
    }
}

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A cancellation the copy's own thread can see (`Task.isCancelled` is false off a task).
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

public enum ProxyMaker {
    /// Long side of the copy. Planner samples are at most a few hundred pixels wide; the video view rarely shows the
    /// picture larger than this.
    public static let longSide = 1280
    /// A keyframe every this many frames: any frame decodes after at most this many others (scrubbing).
    public static let keyFrameInterval = 10
    /// Frames per second the copy keeps at most (dragging shows nothing finer; the exact frame comes from the original).
    public static let maxFrameRate = 30.0
    /// Bump when the copy's recipe changes (size, keyframes, quality, colour handling): cached copies are keyed on it.
    public static let version = 3

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
    /// `gate`: waits there between frames while it is held.
    public static func make(from source: FrameSource, to url: URL, gate: DecodeGate? = nil,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
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
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.6, AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                                              AVVideoAllowFrameReorderingKey: false,
                                              // #0033: an 11-minute aerial's copy was encoder-bound (90 of 120 s)
                                              kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true] as [String: Any],
        ]
        if let colour { writeSettings[AVVideoColorPropertiesKey] = colour }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: writeSettings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.unsupported("cannot write the editing copy") }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        // a stream with temporal layers: decode only those up to `maxFrameRate` (SDR only, see `SubsetDecoder`)
        let layers = source.cheapSubset(forRate: maxFrameRate * 0.99).flatMap { if case .temporalLayers = $0 { $0 } else { nil } }
        if layers == nil, !reader.startReading() { throw EngineError.io("reader failed: \(reader.error?.localizedDescription ?? "?")") }
        guard writer.startWriting() else { throw EngineError.io("writer failed: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        var reported = -1.0
        var lastKept = -Double.infinity
        // a frame closer than this to the last one kept is dropped (24–30 fps sources keep every frame)
        let gap = 1 / maxFrameRate - 0.5 / max(1, source.frameRate)
        func report(_ pts: Double) {
            let done = min(1, pts / max(0.001, source.duration))
            if done - reported >= 0.01 { reported = done; progress(done) }        // whole percents, not every frame
        }
        do {
            if let layers {
                // minutes of synchronous decoding with blocking waits: on a thread of its own, not the task's pool
                // thread (review 11-20)
                let flag = CancelFlag()
                // handed to that one thread and used only there until it is done
                let parts = Unchecked((source: source, input: input, adaptor: adaptor, writer: writer))
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                        let thread = Thread {
                            let (source, input, adaptor, writer) = parts.value
                            do {
                                try source.decode(layers, from: 0, to: source.duration, width: nil,
                                                  pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, storedSize: (w, h)) { pts, buffer in
                                    gate?.pass(cancelled: { flag.isSet })
                                    if flag.isSet { throw CancellationError() }
                                    // a writer that failed (disk full) never gets ready again: stop rather than spin (review)
                                    while !input.isReadyForMoreMediaData {
                                        if flag.isSet { throw CancellationError() }
                                        if writer.status == .failed {
                                            throw EngineError.io("writing the editing copy failed: \(writer.error?.localizedDescription ?? "?")")
                                        }
                                        usleep(2000)
                                    }
                                    guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: pts, preferredTimescale: 600_000)) else {
                                        throw EngineError.io("writing the editing copy failed: \(writer.error?.localizedDescription ?? "?")")
                                    }
                                    report(pts)
                                    return true
                                }
                                done.resume()
                            } catch {
                                done.resume(throwing: error)
                            }
                        }
                        thread.qualityOfService = .userInitiated     // as the task it stands in for (review)
                        thread.start()
                    }
                } onCancel: {
                    flag.set()
                }
            } else {
                while let sample = output.copyNextSampleBuffer() {
                    while gate?.isHeld == true, !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
                    try Task.checkCancellation()
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if pts - lastKept < gap { continue }
                    lastKept = pts
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                    guard input.append(sample) else {
                        throw EngineError.io("writing the editing copy failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    report(pts)
                }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard layers != nil || reader.status == .completed else {
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
