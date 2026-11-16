// Picks the 11 source times of the animation window between a start and an end time.
//
// Rule (docs/research-notes.md 一.2, 一.4): the lock screen plays only the 10 frames before the cover, every step
// should change less than the one before, and the last step has to be small. This is the "shaped path" of the
// prototype (research/pipeline/shaped_path.py) walked BACKWARDS: the cover is fixed at the end; step k (counted from
// the cover) must differ from the pick after it by lambda * weight[k]; the largest lambda for which all ten steps fit
// after the start is used, capped so the last step stays under the comfortable limit.
//
// Why backwards: walking forward from the start and then pinning the last pick to the end only works when ten steps
// happen to reach the end. On content that changes a lot over the range (time-lapses, wind) they stop short and the
// gap to the cover becomes one big last step: exactly the jump the rule forbids (found 2026-11-09 on the sample clips,
// e.g. a night-sky time-lapse: picks ended at 10.55 s, cover at 12.1 s, last step 10). Backwards, the range start is
// only the earliest allowed frame; when the range holds more change than ten small-enough steps can cover, the
// animation simply starts later.
import Foundation

public enum PathPlanner {
    /// Relative size of the 10 steps, taken from the approved H2 clip (10.5 ... 2.4, normalised). Decreasing.
    public static let defaultProfile: [Double] = [1.00, 0.955, 0.896, 0.867, 0.773, 0.734, 0.615, 0.473, 0.346, 0.226]

    /// Upper bound for the planned last step, a little under `WindowAnalysis.lastStepComfortable`: the planner measures
    /// on 96 px thumbnails, the check on 272 px frames, and the two differ by a few tenths.
    public static let lastStepTarget = WindowAnalysis.lastStepComfortable * 0.9

    /// - Parameters:
    ///   - samples: thumbnails of the source between start and end, in order, with their times (use a few per second).
    ///   - endTime: time of the cover frame; default = the last sample. Pass the range's end so a sampling grid that stops
    ///     a few ms short does not move the cover off the true last frame.
    ///   - profile: weights of the 10 steps, first to last (decreasing).
    /// - Returns: 11 times; the last is the cover (`endTime`), the first is at or after the first sample.
    ///   - lastStepTarget: the largest last step to plan for (thumbnail units).
    public static func plan(samples: [(time: Double, image: RGB16Image)], endTime: Double? = nil, profile: [Double] = defaultProfile,
                            lastStepTarget: Double = lastStepTarget) throws -> [Double] {
        guard samples.count >= profile.count + 1 else { throw EngineError.invalid("the selected range is too short for 11 frames") }
        let grey = try samples.map { try rgbThumbnail($0.image) }
        let n = grey.count
        let cover = endTime ?? samples[n - 1].time
        func dist(_ i: Int, _ j: Int) -> Float {
            var s: Float = 0
            for k in 0..<grey[i].count { s += abs(grey[i][k] - grey[j][k]) }
            return s / Float(grey[i].count)
        }
        var cache: [Int: [Float]] = [:]                  // distances from sample j to every earlier sample
        func row(_ j: Int) -> [Float] {
            if let r = cache[j] { return r }
            let r = (0..<n).map { $0 < j ? dist($0, j) : 0 }
            cache[j] = r
            return r
        }
        /// Sample indices of the 11 picks (in time order) for a given step size, or nil if they do not fit.
        /// Whole samples only: with one sample per source frame a pick is a real frame, and no two picks share one
        /// (fractional positions between samples used to round onto the same or a farther frame when decoded).
        func walk(_ lambda: Float) -> [Int]? {
            var picks = [n - 1]
            var j = n - 1
            for w in profile.reversed() {                // from the cover backwards: smallest step first
                let target = lambda * Float(w)
                let r = row(j)
                guard let i = stride(from: j - 1, through: 0, by: -1).first(where: { r[$0] >= target }) else { return nil }
                // the later neighbour is closer to the target from below; take it when it is the nearer one and still a new frame
                let pick = (i + 1 < j && target - r[i + 1] < r[i] - target) ? i + 1 : i
                picks.append(pick)
                j = pick
            }
            return picks.reversed()
        }
        func time(at i: Int) -> Double { samples[i].time }
        let cap = Float(lastStepTarget / profile[profile.count - 1])
        var lo: Float = 1e-4, hi: Float = cap
        guard walk(lo) != nil else {                     // practically no change in the range: spread evenly in time
            var times = (0...profile.count).map { samples[$0 * (n - 1) / profile.count].time }
            times[times.count - 1] = cover
            return times
        }
        if walk(cap) != nil {
            lo = cap                                     // a lot of change: steps as large as the last-step limit allows
        } else {
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if walk(mid) != nil { lo = mid } else { hi = mid }
            }
        }
        var times = walk(lo)!.map(time(at:))
        times[times.count - 1] = cover                   // the animation ends on the last frame of the range
        return times
    }

    /// 11 times spread evenly over the range, the last on `end` (the cover): the whole chosen range plays, at whatever
    /// speed that takes. For content that changes a lot the last step is then large; TailBlend makes it small (#0017).
    public static func even(start: Double, end: Double, steps: Int = defaultProfile.count) throws -> [Double] {
        guard end > start else { throw EngineError.invalid("the selected range is empty") }
        return (0...steps).map { $0 == steps ? end : start + (end - start) * Double($0) / Double(steps) }
    }

    /// Per-channel values, so distances are the same per-channel mean difference the research thresholds use.
    private static func rgbThumbnail(_ image: RGB16Image) throws -> [Float] {
        let w = 96, h = max(1, Int((Double(image.height) / Double(image.width) * 96).rounded()))
        let t = try image.resized(width: w, height: h)
        var v = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { v[i * 3 + c] = Float(t.pixels[i * 4 + c]) / 257 } }
        return v
    }
}
