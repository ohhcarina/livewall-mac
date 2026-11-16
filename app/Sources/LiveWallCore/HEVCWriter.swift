// Encodes the wallpaper clip: HEVC Main, `hvc1`, Display P3 primaries tag, 1/600 timebase.
//
// Rules this must honour (docs/research-notes.md 一.1, 一.3):
//   * long side <= 2176, 8-bit HEVC Main, hvc1;
//   * the colour tag has to be in the file (`colr`): the prototype's ffmpeg route lost it when the tags were passed as
//     encoder options, so the writer's output is checked with `readColorTag` after writing.
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum HEVCWriter {
    public struct Settings {
        public var width: Int
        public var height: Int
        public var fps: Int = 30
        /// VideoToolbox quality 0...1 (the prototype used ffmpeg `-q:v 85`, i.e. 0.85).
        public var quality: Double = 0.85

        public init(width: Int, height: Int, fps: Int = 30, quality: Double = 0.85) {
            self.width = width
            self.height = height
            self.fps = fps
            self.quality = quality
        }
    }

    /// Writes `frames` (Display-P3-encoded RGB) one after another at `fps`.
    public static func write(frames: [RGB16Image], settings: Settings, to url: URL) async throws {
        guard let first = frames.first else { throw EngineError.invalid("no frames to encode") }
        precondition(first.width == settings.width && first.height == settings.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let compression: [String: Any] = [
            AVVideoQualityKey: settings.quality,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoAllowFrameReorderingKey: false,
            // the prototype's ffmpeg encoder produced a sync sample every 12 frames (stss: 0 and 12); keep that
            AVVideoMaxKeyFrameIntervalKey: 12,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 600
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
        ])
        guard writer.canAdd(input) else { throw EngineError.unsupported("cannot add the HEVC input (\(settings.width)x\(settings.height))") }
        writer.add(input)
        guard writer.startWriting() else { throw EngineError.io("writer: \(writer.error?.localizedDescription ?? "cannot start")") }
        writer.startSession(atSourceTime: .zero)

        let ticksPerFrame = 600 / settings.fps
        var cache: [Int: CVPixelBuffer] = [:]                 // identical consecutive frames share one buffer
        var lastKey: UnsafeRawPointer?
        for (i, image) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let key = image.pixels.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress!) }
            let pb: CVPixelBuffer
            if let k = lastKey, k == key, let c = cache[0] { pb = c } else {
                pb = try image.makePixelBuffer()
                cache = [0: pb]
                lastKey = key
            }
            // Tag the buffer so the encoder converts RGB -> YCbCr with the BT.709 matrix, P3 primaries.
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let pts = CMTime(value: CMTimeValue(i * ticksPerFrame), timescale: 600)
            guard adaptor.append(pb, withPresentationTime: pts) else {
                throw EngineError.io("append failed at frame \(i): \(writer.error?.localizedDescription ?? "?")")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw EngineError.io("encode failed: \(writer.error?.localizedDescription ?? "?")") }
    }

    /// Bytes of the largest sample (frame) in the movie's video track; nil when there is no video track.
    /// This is what decides whether iOS enables the motion (research-notes 一.1, rounds 34-35), more than the average.
    public static func maxFrameBytes(of url: URL) throws -> Int? {
        let d = [UInt8](try Data(contentsOf: url))
        guard let moov = try MovBoxes.topLevel(d).first(where: { $0.kind == "moov" }) else { return nil }
        for track in try MovBoxes.children(d, of: moov) where track.kind == "trak" {
            guard try TrackFields.handlerType(d, track) == "vide" else { continue }
            return try TrackFields.sampleSizes(d, track).max()
        }
        return nil
    }

    /// (colour_type, primaries, transfer, matrix) of the first `colr` box in the video sample entry, e.g. ("nclc",12,1,1).
    public static func readColorTag(of url: URL) throws -> (type: String, primaries: Int, transfer: Int, matrix: Int)? {
        let d = [UInt8](try Data(contentsOf: url))
        let moov = try MovBoxes.topLevel(d).first { $0.kind == "moov" }
        guard let moov else { return nil }
        for track in try MovBoxes.children(d, of: moov) where track.kind == "trak" {
            guard try TrackFields.handlerType(d, track) == "vide" else { continue }
            let stsd = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl", "stsd"])
            let entryStart = stsd.dataOffset + 8
            let entrySize = d.be32(entryStart)
            // video sample entry: 8 header + 78 fixed fields, then child boxes
            var o = entryStart + 8 + 78
            while o + 8 <= entryStart + entrySize {
                let size = d.be32(o)
                guard size >= 8 else { break }
                if d.fourcc(o + 4) == "colr" {
                    let type = d.fourcc(o + 8)
                    guard type == "nclc" || type == "nclx" else { return (type, 0, 0, 0) }
                    return (type, Int(d[o + 12]) << 8 | Int(d[o + 13]), Int(d[o + 14]) << 8 | Int(d[o + 15]),
                            Int(d[o + 16]) << 8 | Int(d[o + 17]))
                }
                o += size
            }
        }
        return nil
    }
}
