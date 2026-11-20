import XCTest
@testable import LiveWallCore

final class SegmentPlannerTests: XCTestCase {
    /// `level(i)` per frame, 160x90 grey, 30 fps.
    private func clip(frames count: Int, level: (Int) -> Double) async throws -> FrameSource {
        let w = 160, h = 90
        let frames: [RGB16Image] = (0..<count).map { i in
            var img = RGB16Image(width: w, height: h)
            let v = UInt16(min(255, max(0, level(i))) * 257)
            for p in 0..<(w * h) { img.pixels[p * 4] = v; img.pixels[p * 4 + 1] = v; img.pixels[p * 4 + 2] = v }
            return img
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-seg-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await HEVCWriter.write(frames: frames, settings: .init(width: w, height: h, fps: 30), to: url)
        return try await FrameSource(url: url)
    }

    /// 11-18 GTA logo (rounds 46-48): a still background, and one region (1/64 of the frame) pops in over the last 3
    /// frames. No frame in time is closer, so the plan mixes the tail until that region is close to the cover.
    func testLocalPopInAtTheEndIsMixed() async throws {
        let w = 160, h = 96
        let frames: [RGB16Image] = (0..<60).map { i in
            var img = RGB16Image(width: w, height: h)
            let levels: [Int: Double] = [56: 100, 57: 160, 58: 200, 59: 200]
            let level: Double = levels[i] ?? 40
            for y in 0..<h { for x in 0..<w {
                let value: Double = x < 20 && y < 12 ? level : 40
                let v = UInt16(value * 257), p = (y * w + x) * 4
                img.pixels[p] = v; img.pixels[p + 1] = v; img.pixels[p + 2] = v
            } }
            return img
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-seg-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await HEVCWriter.write(frames: frames, settings: .init(width: w, height: h, fps: 30), to: url)
        let source = try await FrameSource(url: url)
        let plan = try await SegmentPlanner.plan(source: source, start: 1, cover: source.duration - 0.02)
        XCTAssertGreaterThan(plan.blend.max() ?? 0, 0, "the words are mixed in")
        XCTAssertEqual(plan.blend.first, 0)
        var window = try await WindowPlanner.windowFrames(source: source, times: plan.times)
        try TailBlend.apply(&window, alphas: plan.blend)
        for (k, cap) in TailBlend.localTailCap.enumerated() {
            XCTAssertLessThanOrEqual(window[9 - k].localMaxDiff(window[10]), cap + 2)
        }
    }

    func testFeelThresholds() {
        XCTAssertEqual(SegmentPlanner.feel(maxStep: 11), .smooth)
        XCTAssertEqual(SegmentPlanner.feel(maxStep: 15), .jumpy)
        XCTAssertEqual(SegmentPlanner.feel(maxStep: 30), .flashy)
    }

    /// The user's range is played whole, and the last frames are picked closer to the cover so motion turns on
    /// (11-11 R4-2) even when the content changes fast.
    func testPlanUsesTheWholeRangeAndEndsSoftly() async throws {
        let source = try await clip(frames: 90) { 60 + 0.5 * Double($0) }       // steps of 4.5: the tail still needs pulling in
        let cover = source.duration - 0.02
        let plan = try await SegmentPlanner.plan(source: source, start: 0, cover: cover)
        XCTAssertEqual(plan.times.count, 11)
        XCTAssertEqual(plan.times.first!, 0.5 / 30, accuracy: 1e-9)          // mid-frame
        XCTAssertEqual(plan.times.last!, cover, accuracy: 1 / 30.0)
        XCTAssertEqual(plan.blend.max() ?? 0, 0, "the tail is picked, never mixed (R6-1)")
        XCTAssertLessThan(plan.times[10] - plan.times[9], plan.times[1] - plan.times[0], "the last frames close in")
        XCTAssertLessThanOrEqual(plan.report.lastStep, WindowAnalysis.lastStepComfortable)
        XCTAssertEqual(plan.feel, .smooth)
    }

    /// Flicker for the first 4 s, then a slow change: the smoothest start is where the flicker ends.
    func testSmoothestStartStopsWhereTheFlickerBegins() async throws {
        let source = try await clip(frames: 180) { i in i < 120 ? (i % 2 == 0 ? 60 : 180) : 100 + 0.5 * Double(i - 120) }
        let cover = source.duration - 0.02
        let start = try await SegmentPlanner.smoothestStart(source: source, cover: cover)
        XCTAssertGreaterThan(start, 3.9, "must not reach into the flicker")
        XCTAssertLessThan(start, 4.6, "should use most of the calm part")
        let plan = try await SegmentPlanner.plan(source: source, start: start, cover: cover)
        XCTAssertEqual(plan.feel, .smooth)
    }

    /// A short flash 1 s before the cover: starts whose frames land on it are rough, longer ones step over it and are
    /// smooth again (11-18 GTA logo). The bands must show that, not paint everything past the first rough start.
    func testFeelBandsAreNotMonotonic() async throws {
        let source = try await clip(frames: 150) { i in (118...120).contains(i) ? 200 : 100 + 0.1 * Double(i) }
        let cover = source.duration - 0.02
        let bands = try await SegmentPlanner.feelBands(source: source, cover: cover)
        XCTAssertEqual(bands.first?.to ?? 0, cover, accuracy: 1e-9)
        XCTAssertEqual(bands.last?.from, 0)
        for (a, b) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(a.from, b.to, accuracy: 1e-9)
            XCTAssertNotEqual(a.feel, b.feel)
        }
        let firstRough = try XCTUnwrap(bands.firstIndex { $0.feel != .smooth }, "\(bands)")
        XCTAssertTrue(bands[(firstRough + 1)...].contains { $0.feel == .smooth }, "smooth again past the flash: \(bands)")
        let smooth = try await SegmentPlanner.smoothestStart(source: source, cover: cover)
        XCTAssertGreaterThanOrEqual(smooth, bands[firstRough].to - 0.05, "the smoothest start stays before the flash")
    }

    /// A cover within the first 10 frames (11-18 review): nothing to sweep, the whole bar is smooth, never left empty
    /// (an empty answer is never asked again and the bar stayed grey).
    func testFeelBandsNearTheStartAreOneSmoothBand() async throws {
        let source = try await clip(frames: 60) { 60 + 0.5 * Double($0) }
        let bands = try await SegmentPlanner.feelBands(source: source, cover: 10 / 30.0)
        XCTAssertEqual(bands, [SegmentPlanner.FeelBand(from: 0, to: 10 / 30.0, feel: .smooth)])
    }

    func testFrameTimesPickElevenDifferentFrames() {
        let times = SegmentPlanner.frameTimes(start: 24.125 - 10 / 24.0, cover: 24.125, frameRate: 24, duration: 24.125)
        let indices = times.map { Int($0 * 24) }
        XCTAssertEqual(indices, Array(568...578))
        let wide = SegmentPlanner.frameTimes(start: 1, cover: 3, frameRate: 30, duration: 4).map { Int($0 * 30) }
        XCTAssertEqual(wide.first, 30)
        XCTAssertEqual(wide.last, 90)
        XCTAssertEqual(Set(wide).count, 11)
    }

    /// The cover is the frame the person picked, also when the last frames repeat (11-18 「用户有可能会想要最后不动……
    /// 不要直接做」; identical last frames turned motion on in R6-3, R7-1 and R46-3).
    func testRepeatedLastFramesKeepTheCover() async throws {
        let source = try await clip(frames: 60) { 60 + 2 * Double(min($0, 57)) }
        let cover = source.duration - 0.5 / 30
        let plan = try await SegmentPlanner.plan(source: source, start: source.duration - 10 / 30.0, cover: cover)
        XCTAssertEqual(plan.times.last!, cover, accuracy: 0.5 / 30)
        XCTAssertEqual(plan.times.count, 11)
    }

    /// A freeze at the end of a longer stretch (11-18, GTA at 1:17.7): cover and start both stay where they were
    /// chosen; the motion plays, then rests on the still picture.
    func testFrozenEndKeepsCoverAndStart() async throws {
        let source = try await clip(frames: 90) { 60 + 2 * Double(min($0, 70)) }       // still from frame 70 on
        let start = 40.5 / 30, cover = 85.5 / 30
        let plan = try await SegmentPlanner.plan(source: source, start: start, cover: cover)
        XCTAssertEqual(plan.times.last!, cover, accuracy: 0.5 / 30, "the cover the person chose")
        XCTAssertEqual(plan.times.first!, start, accuracy: 0.5 / 30, "the start the person chose")
        XCTAssertLessThan(plan.times[5], 70 / 30.0, "the motion is still in the frames that play")
    }

    /// A slow reveal (11-18, a logo whose background faded in over 3 s): the cover the person picked stays where it is.
    func testSlowRevealKeepsTheCover() async throws {
        let source = try await reveal(frames: 120, framesPerColumn: 1)
        let cover = 110.5 / 30
        let plan = try await SegmentPlanner.plan(source: source, start: cover - 1, cover: cover)
        XCTAssertEqual(plan.times.last!, cover, accuracy: 0.5 / 30)
    }

    /// A bright band over grey that widens by one column every `framesPerColumn` frames, 160x90, 30 fps.
    private func reveal(frames count: Int, framesPerColumn: Int) async throws -> FrameSource {
        let w = 160, h = 90
        let frames: [RGB16Image] = (0..<count).map { i in
            var img = RGB16Image(width: w, height: h)
            for y in 0..<h { for x in 0..<w {
                let v = UInt16((x < i / framesPerColumn ? 160 : 60) * 257), p = (y * w + x) * 4
                img.pixels[p] = v; img.pixels[p + 1] = v; img.pixels[p + 2] = v
            } }
            return img
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-seg-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await HEVCWriter.write(frames: frames, settings: .init(width: w, height: h, fps: 30), to: url)
        return try await FrameSource(url: url)
    }

    /// Every source frame differs from the next by more than a last step may (fireworks, 11-12 R7-2): the cover is
    /// shown twice instead of mixing or skipping.
    func testFastClipRepeatsTheCover() async throws {
        let source = try await clip(frames: 30) { 20 + 7 * Double($0) }
        let cover = source.duration - 0.02
        let plan = try await SegmentPlanner.plan(source: source, start: cover - 10 / 30.0, cover: cover)
        XCTAssertEqual(plan.times[9], plan.times[10], accuracy: 1e-9)
        XCTAssertEqual(plan.report.stepDiffs.last!, 0, accuracy: 0.01)
        XCTAssertEqual(Set(plan.times.dropLast()).count, 10, "the other frames are all different")
        let gaps = zip(plan.times.dropLast(2).dropFirst(), plan.times.dropLast(2)).map { $0 - $1 }
        XCTAssertLessThan(gaps.max()!, 1.5 / 30, "consecutive frames stay consecutive: \(gaps)")
    }

    func testPullTailMovesOnlyWhatIsTooFar() {
        let even = Array(stride(from: 0, through: 100, by: 10))
        let distance = { (i: Int) in Double(100 - i) * 0.5 }            // 0.5 per frame, 5 per even step
        let picks = SegmentPlanner.pullTail(even, targets: [4, 9.5, 16, 21, 30, 40], distance: distance)
        XCTAssertEqual(picks[10], 100)
        XCTAssertEqual(picks[9], 92)                                    // first frame within 4
        XCTAssertEqual(picks[8], 81)                                    // within 9.5
        XCTAssertEqual(picks[4], 40, "far enough back, left where it was")
        XCTAssertEqual(picks, picks.sorted())
    }

    /// A clip that ends on a long still, cover at the very end: the cover stays there, the motion plays before it.
    func testLongFreezeAtTheEnd() async throws {
        let source = try await clip(frames: 120) { 40 + 1.5 * Double(min($0, 79)) }
        let plan = try await SegmentPlanner.plan(source: source, start: 1, cover: source.duration)
        XCTAssertEqual(Int(plan.times.last! * 30), 119)
        XCTAssertLessThan(plan.times.first!, 79 / 30.0)
    }

    func testCalmClipReachesTheBeginning() async throws {
        let source = try await clip(frames: 180) { 60 + 0.3 * Double($0) }
        let start = try await SegmentPlanner.smoothestStart(source: source, cover: source.duration - 0.02)
        XCTAssertEqual(start, 0, accuracy: 0.05)
    }

    /// Calm footage that only needs its last step softened must not get one big step where the pulling starts.
    func testTailClosesInAtTheContentsPace() throws {
        func grey(_ v: Double) -> RGB16Image {
            var img = RGB16Image(width: 16, height: 12)
            let q = UInt16(v * 257)
            for p in 0..<(16 * 12) { img.pixels[p * 4] = q; img.pixels[p * 4 + 1] = q; img.pixels[p * 4 + 2] = q }
            return img
        }
        var window = (0...10).map { grey(40 + 6 * Double($0)) }          // steps of 6: last step too big for the device
        let blend = TailBlend.alphas(window: window, allowed: SegmentPlanner.tailTargets(window))
        try TailBlend.apply(&window, alphas: blend)
        let steps = zip(window.dropFirst(), window).map { $0.meanAbsDiff($1) }
        XCTAssertLessThanOrEqual(steps.last!, 3.05)
        XCTAssertLessThanOrEqual(steps.max()!, 6 * 1.5, "no big step where the pulling starts: \(steps)")
        let dist = window.dropLast().map { $0.meanAbsDiff(window.last!) }
        for (d, cap) in zip(dist.reversed(), SegmentPlanner.tailCap) { XCTAssertLessThanOrEqual(d, cap + 0.05) }
    }
}
