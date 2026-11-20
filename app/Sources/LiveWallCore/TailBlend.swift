// Mixing the last frames of the window toward the cover, so the last step is small whatever the content (#0017).
//
// The device rule (docs/research-notes.md 一.1, 一.4) is that the step from the second-to-last frame into the cover has
// to be small (5.5 worked, 5.7 did not). PathPlanner meets it by spending the ten steps on the calm end of the range,
// which on fast content means only the last instant of the chosen range plays. A blended frame meets it without
// moving the frames: frame' = (1 - a) * frame + a * cover differs from the cover by exactly (1 - a) times as much,
// pixel by pixel, so the mean step into the cover is (1 - a) * D and `a` follows from the wanted step.
//
// Not yet confirmed on a device: that the lock screen accepts a blended frame as a "small last step", and how the
// dissolve looks next to iOS' own blending between frames.
import Foundation

public enum TailBlend {
    /// Largest last step the ramp aims for (WindowAnalysis units), under the comfortable 4.
    public static let lastStepTarget = 3.0
    /// How much farther from the cover each earlier blended frame may stay than the one after it. Steps then grow by
    /// ratio - 1 going backwards (2 would make the last two steps equal); 2.5 matches the end of the approved H2 clip,
    /// whose last three steps sit 0.23, 0.57 and 1.05 (relative) from the cover.
    public static let ratio = 2.5

    /// Mixing weights toward the cover for each frame of `window` (last = cover, weight 0), from the cover backwards:
    /// the second-to-last frame ends `lastStepTarget` from the cover, the one before `ratio` times farther, and so on,
    /// until a frame is already that close. The first frame is never mixed, so the animation starts on real footage.
    /// - Parameter window: the frames as measured for the checks (same size, cropped like the wallpaper).
    public static func alphas(window: [RGB16Image], lastStepTarget: Double = lastStepTarget, ratio: Double = ratio) -> [Double] {
        var alphas = [Double](repeating: 0, count: window.count)
        guard window.count >= 3, let cover = window.last else { return alphas }
        var allowed = lastStepTarget
        for i in stride(from: window.count - 2, through: 1, by: -1) {
            let distance = window[i].meanAbsDiff(cover)
            guard distance > allowed else { break }
            alphas[i] = 1 - allowed / distance
            allowed *= ratio
        }
        return alphas
    }

    /// Mixing weights that put the frames before the cover at given distances from it: `allowed[0]` for the
    /// second-to-last frame, `allowed[1]` for the one before, and so on. A frame already closer stays as it is, and so
    /// do the frames past the end of `allowed` and the first frame.
    public static func alphas(window: [RGB16Image], allowed: [Double]) -> [Double] {
        var alphas = [Double](repeating: 0, count: window.count)
        guard window.count >= 3, let cover = window.last else { return alphas }
        for (k, limit) in allowed.enumerated() {
            let i = window.count - 2 - k
            guard i >= 1 else { break }
            let distance = window[i].meanAbsDiff(cover)
            if distance > limit { alphas[i] = 1 - limit / distance }
        }
        return alphas
    }

    /// How far the frames before the cover may stay from it in the region that changed most (`localMaxDiff`, second-to-
    /// last first). 11-18 GTA logo: words popping in over the last 3 frames on a still background kept that region
    /// 55, 135, 136, 132 away while the mean read 3.4, 8, 13, 16, and motion never turned on (rounds 46-47). The same
    /// frames mixed to 20, 44, 71, 99, 129 (R48-2) and to 10, 21, 35, 50 (R48-1) both did. The first is looser than
    /// R48-2: Mac aerials that turned on stay 22-27 there (Scotland coast, Carrizo plain, Hong Kong), R47-3 55, and
    /// mixing moving footage doubles it (R6-1). Where between these and the failing ones the real limit is was not measured.
    public static let localTailCap: [Double] = [30, 44, 71, 99, 129]

    /// Like `alphas(window:allowed:)`, measured on the region that changed most: mixing scales every pixel's difference
    /// to the cover by (1 - a), so each cell's too, and `a` follows exactly from the limit. Closer to the cover never
    /// mixes less than the frame before (11-18 R51: 0.68 then 0.32 showed the words sharp, soft again, then sharp,
    /// 「末尾auto底部发虚又恢复了」; an App export of the same frames did not turn motion on).
    public static func alphas(window: [RGB16Image], localAllowed: [Double]) -> [Double] {
        var alphas = [Double](repeating: 0, count: window.count)
        guard window.count >= 3, let cover = window.last else { return alphas }
        for (k, limit) in localAllowed.enumerated() {
            let i = window.count - 2 - k
            guard i >= 1 else { break }
            let distance = window[i].localMaxDiff(cover)
            if distance > limit { alphas[i] = 1 - limit / distance }
        }
        for i in 2..<(window.count - 1) { alphas[i] = max(alphas[i], alphas[i - 1]) }
        return alphas
    }

    /// frames[i] = (1 - alphas[i]) * frames[i] + alphas[i] * frames.last, in place. All frames must have the same size.
    public static func apply(_ frames: inout [RGB16Image], alphas: [Double]) throws {
        guard alphas.count == frames.count else {
            throw EngineError.invalid("\(alphas.count) blend weights for \(frames.count) frames")
        }
        guard let cover = frames.last else { return }
        for i in frames.indices where alphas[i] > 0 {
            guard frames[i].width == cover.width, frames[i].height == cover.height else {
                throw EngineError.invalid("blended frames must be the size of the cover")
            }
            let a = Float(min(1, alphas[i])), b = 1 - a
            frames[i].pixels.withUnsafeMutableBufferPointer { px in
                cover.pixels.withUnsafeBufferPointer { c in
                    for k in 0..<px.count where k % 4 != 3 {
                        px[k] = UInt16((b * Float(px[k]) + a * Float(c[k])).rounded())
                    }
                }
            }
        }
    }
}
