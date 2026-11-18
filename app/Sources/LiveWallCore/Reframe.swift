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
    public static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// `area` (fractions) in whole pixels of a source of `size`, inside it and at least 16 pixels each way.
    public static func areaRect(_ area: CGRect, in size: CGSize) -> CGRect {
        let w = Double(size.width), h = Double(size.height)
        let x0 = (min(max(0, Double(area.minX)), 1) * w).rounded(), y0 = (min(max(0, Double(area.minY)), 1) * h).rounded()
        let x1 = (min(max(0, Double(area.maxX)), 1) * w).rounded(), y1 = (min(max(0, Double(area.maxY)), 1) * h).rounded()
        let rw = max(min(16, w), x1 - x0), rh = max(min(16, h), y1 - y0)
        return CGRect(x: min(x0, w - rw), y: min(y0, h - rh), width: rw, height: rh)
    }

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
    ///   - area: the part of the picture kept at all, as fractions of the source (11-18: black bars cut away by hand).
    ///     `.squeeze` fits this part to the screen, `.crop` frames within it.
    public static func plan(sourceSize: CGSize, aspect: Double, mode: ReframeMode, focus: CGPoint = CGPoint(x: 0.5, y: 0.5),
                            area: CGRect = Reframe.wholePicture, maxVideoLongSide: Int? = nil) -> ReframePlan {
        let kept = areaRect(area, in: sourceSize)
        let w = Double(kept.width), h = Double(kept.height)
        let sourceAspect = w / h
        // size of the region that has the target aspect and fits the source without enlarging it
        var regionW = w, regionH = h
        if sourceAspect > aspect { regionW = (h * aspect).rounded() } else { regionH = (w / aspect).rounded() }

        var cropRect = kept
        if mode == .crop {
            let x = ((w - regionW) * Double(min(1, max(0, focus.x)))).rounded()
            let y = ((h - regionH) * Double(min(1, max(0, focus.y)))).rounded()
            cropRect = CGRect(x: kept.minX + x, y: kept.minY + y, width: regionW, height: regionH)
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
