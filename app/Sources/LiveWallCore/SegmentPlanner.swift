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
        /// Mixing toward the cover per frame (`WallpaperRecipe.coverBlend`): zero unless one region stays too far from
        /// the cover after the tail is picked (`TailBlend.localTailCap`).
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
        let small = WindowPlanner.decodeWidth(sampleWidth, crop: crop)
        let shrink = { (image: RGB16Image) in try WindowPlanner.cropped(image, to: crop, width: sampleWidth) }
        // the cover is the frame the person picked, also on a still or repeated stretch: 11-18 「用户有可能会想要最后不动
        // ……可以按需提醒但是不要直接做」. Walking it back to where the picture stopped (from R5-1, 11-11) also caught what
        // was still settling (the bottom of 「auto」 on the GTA logo, 11-18 「auto的底部都是虚的」), and its reason did not
        // hold: identical last frames turned motion on (R6-3, R7-1, R46-3 with all 22 frames the same)
        do {
            let even = frameIndices(start: start, cover: cover, frameRate: fps, duration: source.duration)
            let cover = even[10]
            // the last frames before the cover, one by one: where the step into it can go
            let nearFirst = max(0, cover - nearCount)
            let near = try await source.thumbnails(from: mid(nearFirst, fps), to: mid(cover, fps), fps: fps,
                                                   width: small, transform: shrink).map(\.image)
            try Task.checkCancellation()
            guard near.count > 1 else { throw EngineError.invalid("no frames decoded before the cover") }
            let nearImage = { (index: Int) in near[min(max(0, index - nearFirst), near.count - 1)] }

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
            var frames = try await WindowPlanner.windowFrames(source: source, times: times, crop: crop)
            // picked as close as time allows, one region may still be far from the cover: something popping in over the
            // last frames on a still picture (11-18 GTA logo, rounds 46-48: the mean read 3.5 and motion did not turn
            // on). Only then the tail is mixed; it appears in place, so the mixing reads as the fade it already was
            let blend = TailBlend.alphas(window: frames, localAllowed: TailBlend.localTailCap)
            try TailBlend.apply(&frames, alphas: blend)
            return Plan(times: times, blend: blend, report: try WindowAnalysis.analyze(frames: frames))
        }
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

    /// The earliest start that still looks smooth for this cover: the span grows from 10 source frames by `growth` at a
    /// time and stops at the first one whose largest step (with the tail picked as `plan` does) passes `ceiling`. No
    /// upper limit on how far back (11-11, the user: 「往前取多少让用户决定吧，我们不做限制」); far stretches are sampled more
    /// sparsely and only decoded when everything closer was smooth.
    public static func smoothestStart(source: FrameSource, cover: Double, crop: CGRect = WindowPlanner.fullFrame,
                                      ceiling: Double = smoothStep) async throws -> Double {
        var sweep = StartSweep(source: source, cover: cover, crop: crop)
        while !sweep.isComplete, !sweep.foundRough(above: ceiling), !sweep.reached(startReach) {
            try await sweep.measureNextTier(source: source)
        }
        return try await smoothestStart(source: source, sweep: sweep, ceiling: ceiling)
    }

    /// How far back the automatic start goes at most, and what the App's start row shows (#0033, 11-20): the near
    /// tiers' reach, so the automatic start and the colour bar under the row are known together and never move after.
    /// Footage smooth for longer still lets the person drag further; 20 s already plays 27× fast.
    public static let startReach = 20.0

    /// The smoothest start as far as `sweep` has measured, at most `startReach` back: final once
    /// `StartSweep.knowsSmoothestStart`, otherwise the farthest start measured so far, all of which were smooth.
    public static func smoothestStart(source: FrameSource, sweep: StartSweep, ceiling: Double = smoothStep) async throws -> Double {
        let minSpan = 10 / max(1, source.frameRate)
        let cover = sweep.cover
        guard cover > minSpan else { return 0 }
        // up to the first rough span: farther smooth ones are past a jumpy stretch
        let reached = sweep.points.prefix { $0.maxStep <= ceiling && cover - $0.start <= startReach + 1e-6 }
        let best = reached.last?.start ?? cover - minSpan
        // the samples are small; measured the way the check does, fine texture can read higher: back off until it fits
        var start = max(0, best)
        for _ in 0..<4 {
            let p = try await plan(source: source, start: start, cover: cover, crop: sweep.crop)
            guard p.maxStep > ceiling, cover - start > minSpan * 1.2 else { break }
            start = cover - (cover - start) * 0.85
        }
        return start
    }

    /// How starts in `from..<to` feel: one stretch of the colour bar under the start row.
    public struct FeelBand: Equatable {
        public var from: Double
        public var to: Double
        public var feel: Feel
    }

    /// Bands of `Feel` from 0:00 to the cover (nearest the cover first), measured like `smoothestStart` but without
    /// stopping at the first rough span. How a start feels is not monotonic in how far back it is: 11-18 GTA logo, some
    /// starts put a frame on the instant the logo lit up and stepped over 12, a start 5.6 s back stepped 11.2; the bar,
    /// which painted everything past the first rough span orange and red, sat next to a sidebar saying 平滑.
    public static func feelBands(source: FrameSource, cover: Double, crop: CGRect = WindowPlanner.fullFrame) async throws -> [FeelBand] {
        var sweep = StartSweep(source: source, cover: cover, crop: crop)
        while !sweep.isComplete { try await sweep.measureNextTier(source: source) }
        return feelBands(sweep)
    }

    /// The bands as far as `sweep` has measured: from the cover back `sweep.measuredBack` (to 0:00 once complete).
    public static func feelBands(_ sweep: StartSweep) -> [FeelBand] {
        let cover = sweep.cover
        // nothing to measure (cover in the first 10 frames, or too few samples): smooth, as `smoothestStart` answers 0
        // there. Never empty: an empty answer is not asked again and left the bar grey (11-18 review)
        let whole = [FeelBand(from: 0, to: max(0, cover), feel: .smooth)]
        let points = sweep.points
        guard !points.isEmpty else { return sweep.isComplete ? whole : [] }
        var bands: [FeelBand] = []
        var upper = cover
        for (k, point) in points.enumerated() {
            // each measured start speaks for the stretch halfway to its neighbours; the farthest also for what is left,
            // to 0:00 once there is no more to measure, until then to where its tier reaches (at most 5 % farther)
            let farthest = k == points.count - 1
            let lower = farthest ? (sweep.isComplete ? 0 : max(0, cover - sweep.measuredBack))
                                 : max(0, (point.start + points[k + 1].start) / 2)
            let f = feel(maxStep: point.maxStep)
            if let last = bands.last, last.feel == f {
                bands[bands.count - 1].from = lower
            } else {
                bands.append(FeelBand(from: lower, to: upper, feel: f))
            }
            upper = lower
        }
        return bands
    }

    /// How much longer each measured span is than the one before: 5 %, so the colour bar's bands sit within a few
    /// percent of where the sidebar's exact plan changes its words (15 % left a 5.6 s start judged as 6.3 s, 11-18).
    static let growth = 1.05

    /// Starts from 10 frames back toward 0:00, `growth` farther each, with the largest step of the frames `plan` would
    /// pick (on small samples), measured one sampling tier at a time, nearest first (#0033, 11-19: the App shows what
    /// the near tiers say within seconds and goes on further back after, 「先只算5秒内的先出来，然后再接着考虑之前的」).
    /// Tiers: (how far back, samples per second). 2-8 s back at up to 30 fps: where starts usually go, and 10 fps there
    /// put a 5.6 s start on frames 3 apart from the plan's (11-18 GTA logo); farther back 10 fps, so a tier holds at most
    /// ~200 samples (review: 30 fps out to 20 s was ~600, a quarter gigabyte for portrait crops); the rest at about 2 a
    /// second.
    public struct StartSweep {
        public let cover: Double
        public let crop: CGRect
        /// Nearest the cover first.
        public private(set) var points: [(start: Double, maxStep: Double)] = []
        /// No more to measure: back to 0:00, or nothing left to sample.
        public private(set) var isComplete = false
        private var tier = 0
        private var span: Double
        private let tiers: [(back: Double, fps: Double)]

        public init(source: FrameSource, cover: Double, crop: CGRect = WindowPlanner.fullFrame) {
            self.cover = cover
            self.crop = crop
            let minSpan = 10 / max(1, source.frameRate)
            span = minSpan
            tiers = [(2, source.frameRate), (8, min(source.frameRate, 30)), (20, min(source.frameRate, 10)), (.infinity, 2)]
            isComplete = cover <= minSpan
        }

        /// The tier left is the one over the whole rest of the video, sampled about twice a second.
        public var onlyFarLeft: Bool { tier == tiers.count - 1 }

        /// How far back from the cover the starts measured so far go.
        public var measuredFrom: Double { points.last?.start ?? cover }

        public func foundRough(above ceiling: Double = smoothStep) -> Bool { points.contains { $0.maxStep > ceiling } }

        /// How far back from the cover the tiers measured so far reach (each tier's last start falls up to 5 % short
        /// of its reach, as the spans grow 5 % at a time).
        public private(set) var measuredBack = 0.0

        /// Measured `seconds` back from the cover (or to 0:00).
        public func reached(_ seconds: Double) -> Bool { isComplete || measuredBack >= min(seconds, cover) - 1e-6 }

        /// The smoothest start is known (`SegmentPlanner.smoothestStart(source:sweep:)` will not move with more tiers).
        public var knowsSmoothestStart: Bool { foundRough() || reached(startReach) }

        /// Measures the next tier. `copy` (the editing copy, at most 30 frames a second) samples the 20 s tier and the
        /// farthest one in place of `source` when given: they sample at most 10 a second, a frame near each sample time
        /// is all they ask for, and the original picks those from its 30 fps layer too (#0033: the same answers on 7
        /// videos, 11-20). The 8 s tier samples 30 a second from the original's 60 fps layer, which the copy lacks (it
        /// moved answers by a sample); the 2 s tier needs every frame.
        public mutating func measureNextTier(source: FrameSource, copy: FrameSource? = nil) async throws {
            guard !isComplete, tier < tiers.count else { isComplete = true; return }
            let (back, tierFPS) = tiers[tier]
            tier += 1
            defer { measuredBack = isComplete ? cover : max(measuredBack, min(back, cover)) }
            let from = max(0, cover - back)
            let fps = back.isInfinite ? min(2, 400 / max(1, cover)) : tierFPS
            let width = WindowPlanner.decodeWidth(sampleWidth, crop: crop)
            let crop = self.crop
            let shrink = { (image: RGB16Image) in try WindowPlanner.cropped(image, to: crop, width: sampleWidth) }
            // a coarse look: any frame near each sample time will do, so high-frame-rate streams skip frames (#0033)
            let samples = if tier > 2, let copy {
                try await copy.thumbnails(from: from, to: cover, fps: fps, width: width, transform: shrink)
            } else {
                try await source.thumbnails(from: from, to: cover, fps: fps, width: width, exact: false, transform: shrink)
            }
            try Task.checkCancellation()
            guard samples.count > 1 else { isComplete = true; return }
            while span <= cover - from + 1e-6 {
                let times = (0...10).map { cover - span * Double(10 - $0) / 10 }
                points.append((cover - span, sampledMaxStep(samples, at: times)))
                if span >= cover - 1e-6 { isComplete = true; return }
                span = min(cover, span * growth)
            }
            if tier == tiers.count { isComplete = true }
        }
    }

    static let sampleWidth = 160
    /// Frames before the cover looked at one by one (the step into the cover).
    static let nearCount = 24
    /// Most frames decoded to pick the rest of the tail from.
    static let poolCount = 160


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
