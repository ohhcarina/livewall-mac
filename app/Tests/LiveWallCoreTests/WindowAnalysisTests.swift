import XCTest
@testable import LiveWallCore

final class WindowAnalysisTests: XCTestCase {
    private func flat(_ level: Double) -> RGB16Image {
        let v = UInt16(level * 257)
        var img = RGB16Image(width: 32, height: 24)
        for i in 0..<(32 * 24) { img.pixels[i * 4] = v; img.pixels[i * 4 + 1] = v; img.pixels[i * 4 + 2] = v }
        return img
    }

    func testSteadyBrighteningIsClean() throws {
        let report = try WindowAnalysis.analyze(frames: (0..<11).map { flat(40 + Double($0) * 3) })
        XCTAssertEqual(report.stepDiffs.count, 10)
        for s in report.stepDiffs { XCTAssertEqual(s, 3, accuracy: 0.05) }
        XCTAssertEqual(report.reversalMean, 0, accuracy: 0.01)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testBackAndForthIsFlagged() throws {
        let report = try WindowAnalysis.analyze(frames: (0..<11).map { flat($0 % 2 == 0 ? 40 : 90) })
        XCTAssertGreaterThan(report.reversalMean, WindowAnalysis.reversalWarning)
        XCTAssertTrue(report.findings.contains { $0.severity == .warning && $0.message.contains("往返") })
    }

    func testLastStepThresholds() throws {
        func report(lastStep: Double) throws -> WindowReport {
            var levels = (0..<10).map { 40 + Double($0) }       // nine steps of 1
            levels.append(levels.last! + lastStep)
            return try WindowAnalysis.analyze(frames: levels.map(flat))
        }
        XCTAssertEqual(try report(lastStep: 2).worst, .ok)
        XCTAssertEqual(try report(lastStep: 4.5).worst, .warning)       // 5.5 worked on the device, stay well below
        XCTAssertEqual(try report(lastStep: 6).worst, .error)           // 5.7 did not enable the animation
    }

    func testWrongFrameCountIsReported() throws {
        let report = try WindowAnalysis.analyze(frames: (0..<8).map { flat(40 + Double($0)) })
        XCTAssertTrue(report.findings.contains { $0.message.contains("10 帧") })
    }
}

final class PathPlannerTests: XCTestCase {
    /// Brightness rising linearly by `rise` over 3 seconds, sampled at 60 fps.
    private func ramp(rise: Double) -> [(time: Double, image: RGB16Image)] {
        (0...180).map { i in
            let t = Double(i) / 60
            let v = UInt16(min(255, 20 + t / 3 * rise) * 257)
            var img = RGB16Image(width: 32, height: 24)
            for p in 0..<(32 * 24) { img.pixels[p * 4] = v; img.pixels[p * 4 + 1] = v; img.pixels[p * 4 + 2] = v }
            return (t, img)
        }
    }

    private func steps(_ times: [Double], rise: Double) -> [Double] {
        let level = { (t: Double) in 20 + t / 3 * rise }
        return zip(times.dropFirst(), times).map { level($0) - level($1) }
    }

    func testStepsDecreaseAndUseTheWholeRangeWhenTheChangeIsModest() throws {
        let times = try PathPlanner.plan(samples: ramp(rise: 60))
        XCTAssertEqual(times.count, 11)
        XCTAssertEqual(times.first!, 0, accuracy: 2.0 / 60, "a modest change fits from the range start")
        XCTAssertEqual(times.last!, 3, accuracy: 1e-9)
        XCTAssertEqual(times, times.sorted())
        let s = steps(times, rise: 60)
        for k in 1..<s.count { XCTAssertLessThan(s[k], s[k - 1] + 0.5, "steps must shrink: \(s)") }
        XCTAssertLessThan(s.last!, s.first! * 0.4)
        XCTAssertLessThanOrEqual(s.last!, WindowAnalysis.lastStepComfortable)
    }

    /// The bug this guards: walking forward and pinning the last pick to the end left one big jump into the cover.
    func testTooMuchChangeStartsLaterInsteadOfJumpingIntoTheCover() throws {
        let times = try PathPlanner.plan(samples: ramp(rise: 200))
        XCTAssertEqual(times.last!, 3, accuracy: 1e-9)
        XCTAssertGreaterThan(times.first!, 0.5, "the animation should start later than the range start")
        let s = steps(times, rise: 200)
        XCTAssertLessThanOrEqual(s.last!, WindowAnalysis.lastStepComfortable, "last step \(s.last!) of \(s)")
        for k in 1..<s.count { XCTAssertLessThan(s[k], s[k - 1] + 0.5, "steps must shrink: \(s)") }
    }

    func testTheCoverTimeIsTheRequestedEndEvenIfSamplingStopsShort() throws {
        let samples: [(time: Double, image: RGB16Image)] = (0...170).map { i in
            let v = UInt16(min(255, 20 + Double(i) / 60 * 70) * 257)
            var img = RGB16Image(width: 16, height: 12)
            for p in 0..<(16 * 12) { img.pixels[p * 4] = v; img.pixels[p * 4 + 1] = v; img.pixels[p * 4 + 2] = v }
            return (Double(i) / 60, img)
        }
        XCTAssertEqual(try PathPlanner.plan(samples: samples, endTime: 3.0).last!, 3.0)
        XCTAssertEqual(try PathPlanner.plan(samples: samples).last!, 170.0 / 60, accuracy: 1e-9)
    }

    func testTooShortARangeIsRejected() {
        let one = (0..<5).map { (time: Double($0), image: RGB16Image(width: 8, height: 8)) }
        XCTAssertThrowsError(try PathPlanner.plan(samples: one))
    }
}

final class WindowPlannerTests: XCTestCase {
    /// The Pro Light case in miniature: the left half goes dark and bright again in the first half of the range (a
    /// light band passing), then everything only brightens. A window over the whole range goes back and forth; the
    /// planner has to start after the dip, like the approved 34.5-40 s path did.
    func testStartsAfterABackAndForthRegion() async throws {
        let w = 256, h = 144, fps = 30, seconds = 4.0
        let frames: [RGB16Image] = (0..<Int(seconds * Double(fps))).map { i in
            let t = Double(i) / Double(fps)
            let left = t < 2 ? 200 - 180 * t / 2 : 20 + 200 * (t - 2) / 2
            let right = 40 + 40 * t
            var img = RGB16Image(width: w, height: h)
            for y in 0..<h { for x in 0..<w {
                let v = UInt16(((x < w / 2) ? left : right) * 257), p = (y * w + x) * 4
                img.pixels[p] = v; img.pixels[p + 1] = v; img.pixels[p + 2] = v
            } }
            return img
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-backforth-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await HEVCWriter.write(frames: frames, settings: .init(width: w, height: h, fps: fps), to: url)
        let source = try await FrameSource(url: url)
        let end = source.duration
        let times = try await WindowPlanner.plan(source: source, start: 0, end: end)
        XCTAssertEqual(times.count, 11)
        XCTAssertGreaterThan(times.first!, 1.8, "should start after the dip: \(times)")
        let report = try WindowAnalysis.analyze(frames: try await source.frames(at: times))
        XCTAssertLessThan(report.reversalMean, WindowAnalysis.reversalWarning)
        XCTAssertLessThanOrEqual(report.lastStep, WindowAnalysis.lastStepComfortable)
    }
}
