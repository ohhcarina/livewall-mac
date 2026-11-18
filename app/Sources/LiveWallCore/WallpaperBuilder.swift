// The whole export: source video + recipe -> `<name>.pvt` (HEIC cover + wallpaper MOV + metadata.plist).
import AVFoundation
import CoreGraphics
import Foundation

public struct WallpaperRecipe {
    /// Source times of the animation window, in order. The LAST one is the cover frame and the frame the animation
    /// ends on. The lock screen plays only the 10 frames before the cover (research-notes 一.2), so the usual count is 11.
    public var sourceTimes: [Double]
    /// Per frame of `sourceTimes`, how much it is mixed toward the cover (0 = the source frame as it is; see TailBlend).
    /// Empty = no mixing.
    public var coverBlend: [Double] = []
    /// Target screen aspect, width / height.
    public var aspect: Double
    public var mode: ReframeMode = .squeeze
    public var focus = CGPoint(x: 0.5, y: 0.5)
    /// The part of the picture kept (fractions of the source), see `Reframe.plan`.
    public var area = Reframe.wholePicture
    /// Frames held before / after the window (research-notes 一.1: 5 before and 6 after; none after = not animatable).
    public static let defaultLeadFrames = 5
    public static let defaultTailFrames = 6
    public var leadFrames = WallpaperRecipe.defaultLeadFrames
    public var tailFrames = WallpaperRecipe.defaultTailFrames
    public var fps = 30
    /// Longest side of the wallpaper video; nil = the rule in `Reframe` (portrait is capped lower). Only experiments set it.
    public var maxVideoLongSide: Int?
    public var videoQuality = 0.85
    /// Highest average bitrate of the wallpaper video, bits/s. On the Duo (11-11, R1-R3) the same aurora window was
    /// refused at 72-79 Mbps and accepted at 19 Mbps, and 62 Mbps clouds still worked; grainy footage reaches 70+ at
    /// quality 0.85, so the builder lowers the quality until the video fits. 40 keeps a margin under the 62 that worked.
    public static let defaultMaxVideoBitrate = 40_000_000.0
    public var maxVideoBitrate = WallpaperRecipe.defaultMaxVideoBitrate
    /// Largest single frame of the wallpaper video, bytes. This, not the average, is what iOS refuses (11-13, rounds
    /// 34-36, 2176x1530): <= 729 KB opened, >= 799 KB did not (the middle is untested), and a 35 Mbps video with an
    /// 837 KB keyframe still did not. KB = 1024 bytes. Whether it scales with the picture size is not known; portrait
    /// 884x1920 was never measured, so the same number is used there.
    public static let defaultMaxFrameBytes = 729 * 1024
    public var maxFrameBytes = WallpaperRecipe.defaultMaxFrameBytes
    public var coverQuality = 0.92
    /// Enlarges the video's picture against the cover's (crops a centred border off the video frames only). The lock
    /// screen draws the video about 0.17% smaller than the cover (research-notes 一.2, rounds 29-31 recordings), so sharp
    /// static detail near the edges steps about 1.3 px at hand-off; 1 = off. Rounded to whole source pixels per side.
    public var videoZoom = 1.0

    public init(sourceTimes: [Double], aspect: Double) {
        self.sourceTimes = sourceTimes
        self.aspect = aspect
    }

    /// Index of the cover frame in the video, which is also where still-image-time points.
    public var stillIndex: Int { leadFrames + sourceTimes.count - 1 }
    public var stillImageTime: Double { Double(stillIndex) / Double(fps) }
}

public struct BuildResult {
    public var packageURL: URL
    public var videoSize: (width: Int, height: Int)
    public var coverSize: (width: Int, height: Int)
    public var stillImageTime: Double
    public var assetIdentifier: String
    /// Checks of the animation window measured on the exported video itself (what iOS will play), like the research did.
    public var report: WindowReport
    /// The same checks on the frames before encoding, for comparison.
    public var reportBeforeEncoding: WindowReport
    /// Average bitrate of the video (bits/s) and the encoder quality that produced it (lower than the recipe's when
    /// the bitrate cap kicked in).
    public var videoBitrate: Double
    public var videoQuality: Double
    /// Bytes of the largest frame of the exported video.
    public var maxFrameBytes: Int
}

public enum WallpaperBuilder {
    public static func build(source: FrameSource, recipe: WallpaperRecipe, name: String, outputDirectory: URL,
                             progress: ((String) -> Void)? = nil) async throws -> BuildResult {
        guard recipe.sourceTimes.count >= 2 else { throw EngineError.invalid("need at least 2 frame times") }
        if case .unsupported(let why) = source.sourceColor {
            throw EngineError.unsupported("\(why)，目前没有经过验证的转换，不导出以免颜色出错。")
        }
        // Display P3 sources are already in the target space; HDR ones are decoded as BT.709 SDR
        let convertColor = source.sourceColor != .displayP3
        let plan = Reframe.plan(sourceSize: source.size, aspect: recipe.aspect, mode: recipe.mode, focus: recipe.focus,
                                area: recipe.area, maxVideoLongSide: recipe.maxVideoLongSide)

        progress?("decoding \(recipe.sourceTimes.count) frames")
        let decoded = try await source.frames(at: recipe.sourceTimes)

        progress?("reframing and converting to Display P3")
        let videoCrop = WallpaperBuilder.zoomed(plan.cropRect, by: recipe.videoZoom)
        var window: [RGB16Image] = []
        for image in decoded {
            var frame = try image.resized(width: plan.videoSize.width, height: plan.videoSize.height, crop: videoCrop)
            if convertColor { ColorPipeline.convertSRGBToDisplayP3(&frame) }
            window.append(frame)
        }
        if !recipe.coverBlend.isEmpty { try TailBlend.apply(&window, alphas: recipe.coverBlend) }
        let reportBeforeEncoding = try WindowAnalysis.analyze(frames: window)
        // the cover comes from the same decoded last frame, so video end and cover agree in precision
        var cover = try decoded.last!.resized(width: plan.coverSize.width, height: plan.coverSize.height, crop: plan.cropRect)
        if convertColor { ColorPipeline.convertSRGBToDisplayP3(&cover) }

        let sequence = Array(repeating: window.first!, count: recipe.leadFrames) + window
            + Array(repeating: window.last!, count: recipe.tailFrames)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("livewall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress?("encoding HEVC")
        let encoded = work.appendingPathComponent("encoded.mov")
        let seconds = Double(sequence.count) / Double(recipe.fps)
        var quality = recipe.videoQuality, bitrate = 0.0, maxFrame = 0
        while true {
            try await HEVCWriter.write(frames: sequence, settings: .init(width: plan.videoSize.width, height: plan.videoSize.height,
                                                                         fps: recipe.fps, quality: quality), to: encoded)
            let bytes = (try FileManager.default.attributesOfItem(atPath: encoded.path)[.size] as? NSNumber)?.doubleValue ?? 0
            bitrate = bytes * 8 / seconds
            maxFrame = try HEVCWriter.maxFrameBytes(of: encoded) ?? 0
            guard bitrate > recipe.maxVideoBitrate || maxFrame > recipe.maxFrameBytes else { break }
            guard quality > 0.3 else {
                throw EngineError.invalid(String(format: "video stays at %.0f Mbps with a %d KB largest frame even at quality %.2f",
                                                 bitrate / 1e6, maxFrame / 1024, quality))
            }
            quality = max(0.3, quality - 0.05)
            progress?(String(format: "video at %.0f Mbps, largest frame %d KB is over the %.0f Mbps / %d KB cap, re-encoding at quality %.2f",
                             bitrate / 1e6, maxFrame / 1024, recipe.maxVideoBitrate / 1e6, recipe.maxFrameBytes / 1024, quality))
        }
        guard let tag = try HEVCWriter.readColorTag(of: encoded), tag.primaries == 12 else {
            throw EngineError.invalid("encoder dropped the Display P3 colour tag")
        }

        progress?("writing Live Photo metadata")
        let prepared = try LivePhotoMov.prepareWallpaperVideo([UInt8](try Data(contentsOf: encoded)), stillImageTime: recipe.stillImageTime)
        let movie = work.appendingPathComponent("\(name).mov")
        try Data(prepared).write(to: movie)
        let assetID = UUID().uuidString
        try LivePhotoIdentifier.write(assetID, toMovieAt: movie)

        // measure the window on the file we are about to hand out: compression adds a little difference between frames
        progress?("checking the exported video")
        let exported = try await FrameSource(url: movie)
        let frameTimes = (0..<recipe.sourceTimes.count).map { (Double(recipe.leadFrames + $0) + 0.25) / Double(recipe.fps) }
        // at the width the reversal threshold is defined on (the planner's); smaller frames read low
        let report = try WindowAnalysis.analyze(frames: try await exported.frames(at: frameTimes, width: WindowAnalysis.reversalWidth))

        let heic = work.appendingPathComponent("\(name).heic")
        try CoverWriter.writeHEIC(cover, assetIdentifier: assetID, quality: recipe.coverQuality, to: heic)

        let package = outputDirectory.appendingPathComponent("\(name).pvt")
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: heic, to: package.appendingPathComponent("\(name).heic"))
        try FileManager.default.copyItem(at: movie, to: package.appendingPathComponent("\(name).mov"))
        try pvtMetadataPlist.write(to: package.appendingPathComponent("metadata.plist"), atomically: true, encoding: .utf8)

        return BuildResult(packageURL: package, videoSize: plan.videoSize, coverSize: plan.coverSize,
                           stillImageTime: recipe.stillImageTime, assetIdentifier: assetID, report: report,
                           reportBeforeEncoding: reportBeforeEncoding, videoBitrate: bitrate, videoQuality: quality,
                           maxFrameBytes: maxFrame)
    }

    /// `rect` shrunk about its centre by `zoom`, by the same whole number of pixels on both sides of each axis.
    public static func zoomed(_ rect: CGRect, by zoom: Double) -> CGRect {
        guard zoom > 1 else { return rect }
        let dx = ((rect.width - rect.width / zoom) / 2).rounded(), dy = ((rect.height - rect.height / zoom) / 2).rounded()
        return rect.insetBy(dx: dx, dy: dy)
    }

    static let pvtMetadataPlist = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
        <dict>
            <key>PFVideoComplementMetadataVersionKey</key>
            <string>1</string>
        </dict>
    </plist>
    """
}

/// The Live Photo content identifier in the movie's top-level metadata (`com.apple.quicktime.content.identifier`).
public enum LivePhotoIdentifier {
    static let key = "com.apple.quicktime.content.identifier"

    /// Rewrites only the movie header (like makelive): track data and the `cdsc` track references stay as they are.
    public static func write(_ identifier: String, toMovieAt url: URL) throws {
        let movie = AVMutableMovie(url: url, options: nil)
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = identifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        movie.metadata = movie.metadata.filter { !($0.keySpace == .quickTimeMetadata && ($0.key as? String) == key) } + [item]
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    public static func read(fromMovieAt url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        for item in items where (item.key as? String) == key { return try await item.load(.stringValue) }
        return nil
    }
}
