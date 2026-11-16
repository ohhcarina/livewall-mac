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

    /// The cover at the clip's very end (what the App picks by default) must still give 11 different frames.
    func testFrameTimesPickElevenDifferentFrames() {
        let times = SegmentPlanner.frameTimes(start: 24.125 - 10 / 24.0, cover: 24.125, frameRate: 24, duration: 24.125)
        let indices = times.map { Int($0 * 24) }
        XCTAssertEqual(indices, Array(568...578))
        let wide = SegmentPlanner.frameTimes(start: 1, cover: 3, frameRate: 30, duration: 4).map { Int($0 * 30) }
        XCTAssertEqual(wide.first, 30)
        XCTAssertEqual(wide.last, 90)
        XCTAssertEqual(Set(wide).count, 11)
    }

    /// A clip whose last frames repeat (R5-1, 11-11: three identical frames at the end and motion did not turn on):
    /// the cover moves to the first frame of the repeat, so the last step is a real one.
    func testRepeatedLastFramesAreNotTheTail() async throws {
        let source = try await clip(frames: 60) { 60 + 2 * Double(min($0, 57)) }
        let plan = try await SegmentPlanner.plan(source: source, start: source.duration - 10 / 30.0, cover: source.duration)
        XCTAssertEqual(Int(plan.times.last! * 30), 57)
        XCTAssertGreaterThan(plan.report.stepDiffs.suffix(2).min()!, SegmentPlanner.sameFrame)
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

    /// A clip that ends on a still longer than the frames looked at one by one (11-12 review: 24): the cover still
    /// moves to the first frame of the still.
    func testLongFreezeAtTheEnd() async throws {
        let source = try await clip(frames: 120) { 40 + 1.5 * Double(min($0, 79)) }
        let plan = try await SegmentPlanner.plan(source: source, start: 1, cover: source.duration)
        XCTAssertEqual(Int(plan.times.last! * 30), 79)
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
