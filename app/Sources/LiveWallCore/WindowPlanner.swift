// Plans the 11 frames for a range of a source: the one entry point the app and the CLI share.
//
// Two device rules shape the window (docs/research-notes.md 一.4): the last step into the cover must be small, and no
// region may go back and forth inside the window. PathPlanner handles the first by itself. For the second the fix that
// worked on the device was a shorter window ending on the same cover (Pro Light: 27-40 s rejected, 34.5-40 s
// approved), so when the planned frames go back and forth, the start is moved toward the cover until they do not.
import CoreGraphics
import Foundation

public enum WindowPlanner {
    /// Planned back-and-forth stays a little under `WindowAnalysis.reversalWarning`: it is estimated on the planner's
    /// small samples, the check measures on larger frames.
    public static let reversalTarget = WindowAnalysis.reversalWarning * 0.8
    /// Shortest window the start is moved to; below this the ten steps are nearly identical frames.
    static let shortestSpan = 0.6

    /// - Parameters:
    ///   - start, end: the chosen range; `end` is the cover. The animation may start later than `start`.
    ///   - crop: the part of the picture that ends up on the wallpaper, as fractions of the source (see
    ///     `Reframe.plan`). Everything is measured on it: motion inside a crop scores higher than on the whole frame
    ///     (a 16:9 clip on an iPhone keeps about a quarter of the picture; whole-frame plans came out at a last step of 8.8).
    ///   - maxSamples: upper bound on the frames looked at (long ranges are sampled more sparsely).
    /// - Returns: 11 source times.
    public static func plan(source: FrameSource, start: Double, end: Double, crop: CGRect = fullFrame,
                            maxSamples: Int = 400) async throws -> [Double] {
        let span = max(0.1, end - start)
        // one sample per source frame where affordable: a pick is then a real frame, and the smallest possible step is
        // one frame of motion
        let fps = min(source.frameRate, max(4, Double(maxSamples) / span))
        let samples = try await source.thumbnails(from: start, to: end, fps: fps, width: decodeWidth(192, crop: crop)) {
            try cropped($0, to: crop, width: 192)
        }
        try Task.checkCancellation()

        // The search ranks candidate windows with a cheap estimate on the samples; the real measure (decoded frames,
        // like the check) calibrates it: small and blurred, the estimate sees fine texture such as foam as much calmer
        // (sea-waves sample: 17 estimated, 44 measured), but it ranks windows the same way.
        let estimate = ReversalEstimate(samples: samples)
        func measure(_ times: [Double]) async throws -> WindowReport {
            try await Self.measure(source: source, times: times, crop: crop)
        }
        var chosen = (times: try PathPlanner.plan(samples: samples, endTime: end), from: samples)
        var report = try await measure(chosen.times)
        var real: Double { report.reversalMean }
        for _ in 0..<3 where real > reversalTarget {
            let scale = real / max(0.01, try estimate.value(at: chosen.times))
            // shorter windows on the same cover until the estimate says nothing goes back and forth
            var best = (times: chosen.times, from: chosen.from, value: real)
            var times = chosen.times
            var lastCount = samples.count + 1
            while best.value > reversalTarget, let first = times.first, end - first > shortestSpan {
                let s = end - max(shortestSpan, (end - first) * 0.8)
                let from = samples.filter { $0.time >= s - 1e-6 }
                // stop when a round drops no sample: at the shortest span `s` stops moving, and a sample a few ulp
                // below it kept `end - first` just over the limit forever (25/30/50/60 fps clips)
                guard from.count > PathPlanner.defaultProfile.count, from.count < lastCount else { break }
                lastCount = from.count
                times = try PathPlanner.plan(samples: from, endTime: end)
                let v = try estimate.value(at: times) * scale
                if v < best.value { best = (times, from, v) }
                try Task.checkCancellation()
            }
            guard best.times != chosen.times else { break }  // nothing shorter looks better
            let measured = try await measure(best.times)
            guard measured.reversalMean < real else { break }
            chosen = (best.times, best.from)
            report = measured
        }
        return try await verifyLastStep(source: source, samples: chosen.from, end: end, crop: crop, times: chosen.times,
                                        measured: report.lastStep)
    }

    public static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The checks (WindowAnalysis) on the frames at `times`, cropped as on the wallpaper, at the width the device
    /// thresholds were calibrated on.
    /// `blend`: mixing toward the cover as in `WallpaperRecipe.coverBlend` (empty = none), applied like the export does.
    public static func measure(source: FrameSource, times: [Double], crop: CGRect = fullFrame,
                               blend: [Double] = []) async throws -> WindowReport {
        var frames = try await windowFrames(source: source, times: times, crop: crop)
        if !blend.isEmpty { try TailBlend.apply(&frames, alphas: blend) }
        return try WindowAnalysis.analyze(frames: frames)
    }

    /// The frames at `times` as the checks see them: cropped like the wallpaper, `WindowAnalysis.reversalWidth` across.
    public static func windowFrames(source: FrameSource, times: [Double], crop: CGRect = fullFrame) async throws -> [RGB16Image] {
        let frames = try await source.frames(at: times, width: decodeWidth(WindowAnalysis.reversalWidth, crop: crop))
        return try frames.map { try cropped($0, to: crop, width: WindowAnalysis.reversalWidth) }
    }

    /// Decode wide enough that the crop alone is `width` across (capped, for thin crops of large sources).
    /// The width `windowFrames` decodes at for this crop: pictures of the planned frames decoded at it come from what
    /// the plan has just decoded (`FrameSource`'s cache) instead of being decoded again (#0033).
    public static func measuredWidth(crop: CGRect) -> Int { decodeWidth(WindowAnalysis.reversalWidth, crop: crop) }

    static func decodeWidth(_ width: Int, crop: CGRect) -> Int {
        min(width * 4, Int((Double(width) / max(0.05, Double(crop.width))).rounded(.up)))
    }

    /// `image` cut to `crop` (fractions) and scaled to `width` across, keeping the crop's proportions.
    static func cropped(_ image: RGB16Image, to crop: CGRect, width: Int) throws -> RGB16Image {
        guard crop != fullFrame else { return image }
        let w = Double(image.width), h = Double(image.height)
        let x = min(max(0, (crop.minX * w).rounded()), w - 1), y = min(max(0, (crop.minY * h).rounded()), h - 1)
        let cw = max(1, min(w - x, (crop.width * w).rounded())), ch = max(1, min(h - y, (crop.height * h).rounded()))
        let outW = min(width, Int(cw)), outH = max(1, Int((Double(outW) * ch / cw).rounded()))
        return try image.resized(width: outW, height: outH, crop: CGRect(x: x, y: y, width: cw, height: ch))
    }

    /// The planner measures on small thumbnails, the check (and the device thresholds) on WindowAnalysis' larger ones;
    /// fine texture such as breaking waves looks calmer small. Measure the planned last step the way the check does,
    /// and tighten the target when it came out too large (2026-11-09: sea-waves sample planned 3.6, measured 6.0).
    private static func verifyLastStep(source: FrameSource, samples: [(time: Double, image: RGB16Image)], end: Double,
                                       crop: CGRect, times planned: [Double], measured first: Double) async throws -> [Double] {
        var times = planned
        var target = PathPlanner.lastStepTarget
        var measured = first
        for attempt in 0..<2 {
            if attempt > 0 {
                measured = try await measure(source: source, times: Array(times.suffix(2)), crop: crop).lastStep
                try Task.checkCancellation()
            }
            guard measured > WindowAnalysis.lastStepComfortable, measured > 0 else { break }
            target *= WindowAnalysis.lastStepComfortable * 0.9 / measured
            times = try PathPlanner.plan(samples: samples, endTime: end, lastStepTarget: target)
        }
        return times
    }
}

/// WindowAnalysis' back-and-forth measure on the planner's samples, small and blurred (96 px, 3 px box): only for
/// ranking candidate windows, see `plan`.
private final class ReversalEstimate {
    let samples: [(time: Double, image: RGB16Image)]
    private var greys: [Int: [Float]] = [:]
    private var height = 0
    private let width = 96

    init(samples: [(time: Double, image: RGB16Image)]) { self.samples = samples }

    func value(at times: [Double]) throws -> Double {
        let frames = try times.map { t -> [Float] in
            // nearest sample; the cover time may sit a few ms after the last sample
            let i = samples.indices.min { abs(samples[$0].time - t) < abs(samples[$1].time - t) }!
            if let g = greys[i] { return g }
            let g = try WindowAnalysis.grey(samples[i].image, width: width)
            height = g.height
            greys[i] = g.values
            return g.values
        }
        let map = WindowAnalysis.reversalMap(grey: frames, width: width, height: height, blur: 3)
        return Double(map.reduce(0, +)) / Double(max(1, map.count))
    }
}
