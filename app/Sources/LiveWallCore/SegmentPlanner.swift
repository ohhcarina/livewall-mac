// The App's frame picking since 11-11 (#0017): the user picks the cover and how far back to go; the tool plays that
// whole stretch and only tells how it will feel.
//
// What the Duo showed (docs/research-notes.md, rounds 15-18):
//   * motion turns on when the last 4 frames close in on the cover, whatever comes before (R4-2). Until 11-12 the tail
//     was mixed toward the cover (TailBlend); mixing doubled moving things (R6-1 「末尾让人眩晕」), so now the last
//     frames are picked closer to the cover instead (`pullTail`);
//   * the lock screen plays 10 frames in ~0.75 s, so a longer stretch is a faster fast-forward: calm footage stays smooth
//     over many seconds, fast footage (fireworks) flashes beyond about half a second. How smooth is a property of the
//     content and the length, reported as `Feel`, never forced on the user.
import CoreGraphics
import Foundation

public enum SegmentPlanner {
    public enum Feel: Equatable { case smooth, jumpy, flashy }

    /// Largest step (WindowAnalysis units) that still looks smooth: the approved Pro Light clip (H2) steps about 11.
    public static let smoothStep = 12.0
    /// Above this it flashes: the 6 s fireworks of round 18 stepped 18-27 and looked "very strange" to the user.
    public static let jumpyStep = 20.0
    /// Farthest the last 4 frames may stay from the cover (second-to-last first). On the Duo motion turned on with
    /// D (0.1, 9.7, 16.4, 21.3) and R4-2 (3, 7, 12, 18), and not with E (2.8, 7.0, 18.2, 34.3): staying at or under D,
    /// with a last step of 3 (proven many times), keeps to what the device accepted.
    public static let tailCap: [Double] = [3, 9.5, 16, 21]

    /// Where the last frames should sit: a straight line from the cover (3 away) to the seventh frame before it, so
    /// the tail closes in at an even pace over 6 frames, and the last 4 never past `tailCap`. Pulling in fewer frames
    /// left one big step where the pulling started (mountain fog 11-11: steps of 6, then one of 11.5).
    public static func tailTargets(_ window: [RGB16Image]) -> [Double] {
        let reach = 6
        guard window.count >= reach + 2, let cover = window.last else { return tailCap }
        let anchor = window[window.count - 2 - reach].meanAbsDiff(cover)
        return (0..<reach).map { k in
            let line = 3 + (anchor - 3) * Double(k) / Double(reach)
            return k < tailCap.count ? min(tailCap[k], line) : line
        }
    }

    public static func feel(maxStep: Double) -> Feel {
        maxStep <= smoothStep ? .smooth : (maxStep <= jumpyStep ? .jumpy : .flashy)
    }

    public struct Plan {
        /// 11 source times (mid-frame), from the start to the cover: even, except the last frames, which close in on
        /// the cover; the frame before the cover may be the cover itself (`holdAbove`).
        public var times: [Double]
        /// Mixing toward the cover per frame (`WallpaperRecipe.coverBlend`): no longer used by the App (all zero).
        public var blend: [Double]
        /// Checks on the frames as they will play, cropped like the wallpaper.
        public var report: WindowReport
        public var maxStep: Double { report.stepDiffs.max() ?? 0 }
        public var feel: Feel { SegmentPlanner.feel(maxStep: maxStep) }
    }

    /// Above this the frame right before the cover is too far from it for the last step (research: 5.5 opened, 5.7
    /// did not; clouds at 3.3 opened, R6-2): the cover is shown twice instead, which opened and looked smooth with
    /// fireworks (R7-2, and D in round 15).
    public static let holdAbove = WindowAnalysis.lastStepComfortable

    /// Plays the whole stretch from `start` to `cover`; the last frames close in on the cover by being picked closer to
    /// it in time, never by mixing (11-12: mixing doubled moving things and made the end dizzying, R6-1; the same
    /// fireworks unmixed were smooth, R7-2).
    public static func plan(source: FrameSource, start: Double, cover: Double,
                            crop: CGRect = WindowPlanner.fullFrame) async throws -> Plan {
        guard cover > start else { throw EngineError.invalid("the selected range is empty") }
        let fps = max(1, source.frameRate)
        var coverTime = cover, startTime = start
        let small = WindowPlanner.decodeWidth(sampleWidth, crop: crop)
        let shrink = { (image: RGB16Image) in try WindowPlanner.cropped(image, to: crop, width: sampleWidth) }
        // a freeze longer than the frames looked at one by one is walked back in several passes
        let passes = 5
        for attempt in 0..<passes {
            let even = frameIndices(start: startTime, cover: coverTime, frameRate: fps, duration: source.duration)
            let cover = even[10]
            // the last frames before the cover, one by one: repeats at the cover, and where the step into it can go
            let nearFirst = max(0, cover - nearCount)
            let near = try await source.thumbnails(from: mid(nearFirst, fps), to: mid(cover, fps), fps: fps,
                                                   width: small, transform: shrink).map(\.image)
            try Task.checkCancellation()
            guard near.count > 1 else { throw EngineError.invalid("no frames decoded before the cover") }
            let nearImage = { (index: Int) in near[min(max(0, index - nearFirst), near.count - 1)] }
            // a cover on a repeated or frozen frame becomes the first frame showing that picture
            var repeats = 0
            while cover - repeats - 1 >= max(10, nearFirst),
                  nearImage(cover - repeats).meanAbsDiff(nearImage(cover - repeats - 1)) < sameFrame { repeats += 1 }
            if attempt < passes - 1, repeats > 0 {
                // the start moves with it: the same stretch, the same spacing (else one gap doubles, 11-12 R8)
                coverTime = mid(cover - repeats, fps)
                startTime = max(0, startTime - Double(repeats) / fps)
                continue
            }

            // what the tail is picked from: frames from the 7th pick to the cover (the last 4 only move after it), at
            // most `poolCount` of them, evenly thinned on long stretches (11-12 review: every frame of a minute-long
            // calm stretch at 60 fps was over a gigabyte); and the 4th pick, whose distance sets the targets
            let stride = max(1, (cover - even[6] + poolCount - 1) / poolCount)
            let steps = min(cover / stride, (cover - even[6] + stride - 1) / stride)
            let poolFirst = cover - steps * stride
            let pool = steps == 0 ? [] : try await source.thumbnails(from: mid(poolFirst, fps), to: mid(cover, fps),
                                                                      fps: fps / Double(stride), width: small,
                                                                      transform: shrink).map(\.image)
            let anchor = try await source.frames(at: [mid(even[3], fps)], width: small).map(shrink)
            try Task.checkCancellation()
            let image = { (index: Int) -> RGB16Image in
                if index >= nearFirst { return nearImage(index) }
                if index == even[3] || pool.isEmpty { return anchor[0] }
                return pool[min(max(0, (index - poolFirst + stride / 2) / stride), pool.count - 1)]
            }
            let coverImage = nearImage(cover)
            let window = [anchor[0]] + even[4...].map(image)
            var picks = pullTail(even, targets: pullTargets(window)) { image($0).meanAbsDiff(coverImage) }
            // the step into the cover, measured at full size (fine texture reads higher than on the small frames): the
            // pick if close enough, else the earliest of the last `nearCount` frames that is, else the cover twice
            if picks[9] != cover {
                let candidates = [picks[9]] + (max(picks[9] + 1, cover - nearCount)..<cover)
                let full = try await WindowPlanner.windowFrames(source: source, times: (candidates + [cover]).map { mid($0, fps) },
                                                                crop: crop)
                if let i = candidates.indices.first(where: { full[$0].meanAbsDiff(full[full.count - 1]) <= holdAbove }) {
                    picks[9] = candidates[i]
                } else {
                    // the cover twice; the other 10 evenly again, then the tail pulled as before
                    picks = pullTail(even, targets: [-1] + pullTargets(window).dropFirst()) { image($0).meanAbsDiff(coverImage) }
                }
            }
            let times = picks.map { mid($0, fps) }
            let frames = try await WindowPlanner.windowFrames(source: source, times: times, crop: crop)
            return Plan(times: times, blend: Array(repeating: 0, count: times.count),
                        report: try WindowAnalysis.analyze(frames: frames))
        }
        throw EngineError.invalid("could not plan the frames")
    }

    /// Distance limits for the last 4 frames before the cover (second-to-last first): `tailTargets` from the window
    /// (picks 3 to 10), with the step into the cover allowed up to `holdAbove`. Only these 4: the device needs them
    /// (R4-2), and moving earlier frames only skips source frames where they are already consecutive (11-12 R8: the
    /// default fireworks got a step of 17.7 that way).
    static func pullTargets(_ window: [RGB16Image]) -> [Double] {
        var targets = Array(tailTargets(window).prefix(tailCap.count))
        targets[0] = max(targets[0], holdAbove)
        return targets
    }

    /// The 11 `even` picks with the last ones moved later (toward the cover, index 10) until each is within its target
    /// distance of the cover: the earliest frame that is, else the closest one. When no frame before the cover is
    /// close enough, the cover is shown twice and the other 10 are spread evenly again (so no gap doubles where the
    /// repeat goes, 11-12 R8). Works on any increasing frame numbers.
    static func pullTail(_ even: [Int], targets: [Double], distance: (Int) -> Double) -> [Int] {
        let c = even.count - 1, s = even[0], cover = even[c]
        // frames about one source frame apart can only be moved by skipping one, which doubles a step (11-12 R8: the
        // default fireworks); the same frames unmoved, with the cover repeated, opened and looked smooth (R7-2)
        let consecutive = Double(cover - s) / Double(c) < 1.5
        var picks = even
        if let limit = targets.first, distance(even[c - 1]) > limit,
           !(even[c - 1]..<cover).contains(where: { distance($0) <= limit }) {
            picks = consecutive
                ? Array(even.dropFirst()) + [cover]         // one frame later, as R7-2: every step stays one frame
                : (0..<c).map { s + Int((Double(cover - s) * Double($0) / Double(c - 1)).rounded()) } + [cover]
        }
        for (k, limit) in targets.enumerated() {
            let i = c - 1 - k
            guard i >= 1, !consecutive else { break }
            let lo = picks[i], hi = picks[i + 1] - 1
            if distance(lo) <= limit || lo > hi { continue }
            if let j = (lo...hi).first(where: { distance($0) <= limit }) {
                picks[i] = j
            } else {
                picks[i] = (lo...hi).min { distance($0) < distance($1) || (distance($0) == distance($1) && $0 > $1) }!
            }
        }
        return picks
    }

    /// The earliest start that still looks smooth for this cover: the span grows from 10 source frames by 15 % at a
    /// time and stops at the first one whose largest step (with the tail picked as `plan` does) passes `ceiling`. No
    /// upper limit on how far back (11-11, the user: 「往前取多少让用户决定吧，我们不做限制」); far stretches are sampled more
    /// sparsely and only decoded when everything closer was smooth.
    public static func smoothestStart(source: FrameSource, cover: Double, crop: CGRect = WindowPlanner.fullFrame,
                                      ceiling: Double = smoothStep) async throws -> Double {
        let minSpan = 10 / max(1, source.frameRate)
        guard cover > minSpan else { return 0 }
        // sampling tiers: (how far back, samples per second)
        let tiers: [(back: Double, fps: Double)] = [(2, source.frameRate), (20, min(source.frameRate, 10)), (.infinity, 2)]
        var best = cover - minSpan
        var span = minSpan
        tierLoop: for tier in tiers {
            let from = max(0, cover - tier.back)
            let fps = tier.back.isInfinite ? min(2, 400 / max(1, cover)) : tier.fps
            let samples = try await source.thumbnails(from: from, to: cover, fps: fps,
                                                      width: WindowPlanner.decodeWidth(sampleWidth, crop: crop)) {
                try WindowPlanner.cropped($0, to: crop, width: sampleWidth)
            }
            try Task.checkCancellation()
            guard samples.count > 1 else { break }
            while span <= cover - from + 1e-6 {
                let times = (0...10).map { cover - span * Double(10 - $0) / 10 }
                if sampledMaxStep(samples, at: times) > ceiling { break tierLoop }
                best = cover - span
                if span >= cover - 1e-6 { break tierLoop }
                span = min(cover, span * 1.15)
            }
        }
        // the samples are small; measured the way the check does, fine texture can read higher: back off until it fits
        var start = max(0, best)
        for _ in 0..<4 {
            let p = try await plan(source: source, start: start, cover: cover, crop: crop)
            guard p.maxStep > ceiling, cover - start > minSpan * 1.2 else { break }
            start = cover - (cover - start) * 0.85
        }
        return start
    }

    static let sampleWidth = 160
    /// Frames before the cover looked at one by one (repeats, the step into the cover).
    static let nearCount = 24
    /// Most frames decoded to pick the rest of the tail from.
    static let poolCount = 160

    /// Below this (WindowAnalysis units) two frames are the same picture: repeated frames measure about 0.1 (codec
    /// noise), the smallest real step seen in the samples is about 2.
    static let sameFrame = 1.0

    private static func mid(_ index: Int, _ fps: Double) -> Double { (Double(index) + 0.5) / fps }

    /// Frame numbers of 11 different frames, evenly from the start to the cover (the frame shown at `cover`).
    static func frameIndices(start: Double, cover: Double, frameRate: Double, duration: Double) -> [Int] {
        let fps = max(1, frameRate), steps = 10
        let last = max(steps, Int((duration * fps).rounded()) - 1)
        let c = min(last, max(steps, Int((cover * fps + 1e-6).rounded(.down))))
        let s = max(0, min(c - steps, Int((start * fps + 1e-6).rounded(.down))))
        return (0...steps).map { s + Int((Double(c - s) * Double($0) / Double(steps)).rounded()) }
    }

    /// `frameIndices` as mid-frame times, so rounding never picks one frame twice. Even times fall on frame boundaries,
    /// where floating-point error picks the frame before about every third time (11-11 R5-1 got three identical frames
    /// at the end that way).
    public static func frameTimes(start: Double, cover: Double, frameRate: Double, duration: Double) -> [Double] {
        let fps = max(1, frameRate)
        return frameIndices(start: start, cover: cover, frameRate: fps, duration: duration).map { mid($0, fps) }
    }

    private static func sampledMaxStep(_ samples: [(time: Double, image: RGB16Image)], at times: [Double]) -> Double {
        let even = times.map { t in samples.indices.min { abs(samples[$0].time - t) < abs(samples[$1].time - t) }! }
        let cover = samples[even[10]].image
        let picks = pullTail(even, targets: pullTargets(even[3...].map { samples[$0].image })) {
            samples[$0].image.meanAbsDiff(cover)
        }
        let frames = picks.map { samples[$0].image }
        return zip(frames.dropFirst(), frames).map { $0.meanAbsDiff($1) }.max() ?? 0
    }
}
