// Fitting a source video to a phone screen's aspect ratio, and to the resolution cap of the wallpaper video.
//
// Two ways (docs/research-notes.md 一.5): `squeeze` rescales the whole picture non-uniformly (what the user picked on
// the iPhone Duo), `crop` cuts the target aspect out of the picture around a focus point.
import CoreGraphics
import Foundation

public enum ReframeMode: String, CaseIterable, Sendable {
    case squeeze
    case crop
}

public struct ReframePlan: Equatable {
    /// Part of the source that is used (the whole frame when squeezing).
    public var cropRect: CGRect
    /// Size of the full-resolution cover (never larger than the source).
    public var coverSize: (width: Int, height: Int)
    /// Size of the video (long side capped, even dimensions).
    public var videoSize: (width: Int, height: Int)

    /// `cropRect` as fractions of a source of `sourceSize`: the part the planner and the checks measure on, so they see
    /// the same picture the wallpaper shows.
    public func cropFraction(of sourceSize: CGSize) -> CGRect {
        CGRect(x: cropRect.minX / sourceSize.width, y: cropRect.minY / sourceSize.height,
               width: cropRect.width / sourceSize.width, height: cropRect.height / sourceSize.height)
    }

    public static func == (a: ReframePlan, b: ReframePlan) -> Bool {
        a.cropRect == b.cropRect && a.coverSize == b.coverSize && a.videoSize == b.videoSize
    }
}

public enum Reframe {
    /// The research found the video's *long side* must stay <= 2176 (2304 failed; the cover has no such limit).
    public static let maxVideoLongSide = 2176
    /// A portrait video is capped lower: 884x1920 enabled motion but 900x1952 up to 1002x2176 did not (rounds 37-38,
    /// 11-14, iPhone 0.46 aspect). 1920 is the highest tested to work; other portrait shapes (iPad, Duo upright) were
    /// not tested, so they get the same cap.
    public static let maxPortraitVideoLongSide = 1920

    /// - Parameters:
    ///   - sourceSize: displayed size of the source in pixels.
    ///   - aspect: target width / height, e.g. 1.4222 for the iPhone Duo inner screen used landscape.
    ///   - focus: for `.crop`, where the window sits (0...1 on each axis; 0.5 = centred).
    public static func plan(sourceSize: CGSize, aspect: Double, mode: ReframeMode, focus: CGPoint = CGPoint(x: 0.5, y: 0.5),
                            maxVideoLongSide: Int? = nil) -> ReframePlan {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        let sourceAspect = w / h
        // size of the region that has the target aspect and fits the source without enlarging it
        var regionW = w, regionH = h
        if sourceAspect > aspect { regionW = (h * aspect).rounded() } else { regionH = (w / aspect).rounded() }

        var cropRect = CGRect(x: 0, y: 0, width: w, height: h)
        if mode == .crop {
            let x = ((w - regionW) * Double(min(1, max(0, focus.x)))).rounded()
            let y = ((h - regionH) * Double(min(1, max(0, focus.y)))).rounded()
            cropRect = CGRect(x: x, y: y, width: regionW, height: regionH)
        }
        let coverW = Int(regionW), coverH = Int(regionH)

        // video: same aspect as the cover, long side capped, even dimensions for 4:2:0
        let cap = maxVideoLongSide ?? (coverH > coverW ? maxPortraitVideoLongSide : Reframe.maxVideoLongSide)
        let scale = min(1.0, Double(cap) / Double(max(coverW, coverH)))
        var videoW = Int((Double(coverW) * scale).rounded()), videoH = Int((Double(coverH) * scale).rounded())
        videoW -= videoW % 2
        videoH -= videoH % 2
        return ReframePlan(cropRect: cropRect, coverSize: (coverW, coverH), videoSize: (videoW, videoH))
    }
}
