import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import LiveWallCore

final class TailBlendTests: XCTestCase {
    private func grey(_ v: Double, width: Int = 32, height: Int = 24) -> RGB16Image {
        var img = RGB16Image(width: width, height: height)
        let q = UInt16(min(255, max(0, v)) * 257)
        for p in 0..<(width * height) { img.pixels[p * 4] = q; img.pixels[p * 4 + 1] = q; img.pixels[p * 4 + 2] = q }
        return img
    }

    func testBlendedTailLandsOnTheTargetLastStepAndKeepsTheStart() throws {
        // steady brightening by 18 a step: unblended, the last step is 18, far over the device limit
        var window = (0...10).map { grey(20 + 18 * Double($0)) }
        let alphas = TailBlend.alphas(window: window)
        XCTAssertEqual(alphas.first, 0)
        XCTAssertEqual(alphas.last, 0)
        try TailBlend.apply(&window, alphas: alphas)
        let report = try WindowAnalysis.analyze(frames: window)
        XCTAssertEqual(report.lastStep, TailBlend.lastStepTarget, accuracy: 0.05)
        let tail = Array(report.stepDiffs.suffix(3))
        XCTAssertGreaterThan(tail[0], tail[1])
        XCTAssertGreaterThan(tail[1], tail[2])
        XCTAssertEqual(window[0].pixels[0], grey(20).pixels[0], "the first frame stays real footage")
    }

    func testCalmContentIsNotBlended() {
        let window = (0...10).map { grey(100 + 0.2 * Double($0)) }
        XCTAssertEqual(TailBlend.alphas(window: window), [Double](repeating: 0, count: 11))
    }

    func testApplyMixesTowardTheCover() throws {
        var frames = [grey(0), grey(100), grey(200)]
        try TailBlend.apply(&frames, alphas: [0, 0.5, 0])
        XCTAssertEqual(Double(frames[1].pixels[0]) / 257, 150, accuracy: 0.01)
        XCTAssertEqual(frames[0].pixels[0], 0)
        XCTAssertThrowsError(try TailBlend.apply(&frames, alphas: [0, 0.5]))
    }

    /// 640x360: the left half stays grey 60, the right half brightens by 6 a frame (24 fps).
    private func writeHalfRampClip(frames: Int = 36) async throws -> URL {
        let width = 640, height = 360
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-tb-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                          AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let left = 60.0 / 255, right = (20 + 6 * Double(i)) / 255
            ctx.setFillColor(CGColor(red: left, green: left, blue: left, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            ctx.setFillColor(CGColor(red: right, green: right, blue: right, alpha: 1))
            ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// The planner's measure, the builder's check before encoding and the check on the exported video must see the same
    /// picture (the crop) and the same frames (blended): in 11-10 review the plan was measured on the whole frame while
    /// the export was cropped, and a planned 4 came out as 8.8.
    func testPlanCheckAndExportMeasureTheSameCroppedBlendedFrames() async throws {
        let source = try await FrameSource(url: try await writeHalfRampClip())
        var recipe = WallpaperRecipe(sourceTimes: try PathPlanner.even(start: 0, end: 1.4), aspect: 0.5)
        recipe.mode = .crop
        recipe.focus = CGPoint(x: 1, y: 0.5)                       // only the brightening half is on the wallpaper
        let crop = Reframe.plan(sourceSize: source.size, aspect: recipe.aspect, mode: recipe.mode, focus: recipe.focus)
            .cropFraction(of: source.size)
        XCTAssertGreaterThanOrEqual(crop.minX, 0.5)

        let frames = try await WindowPlanner.windowFrames(source: source, times: recipe.sourceTimes, crop: crop)
        recipe.coverBlend = TailBlend.alphas(window: frames)
        XCTAssertGreaterThan(recipe.coverBlend.max() ?? 0, 0, "the ramp is too fast for an unblended last step")
        let planned = try await WindowPlanner.measure(source: source, times: recipe.sourceTimes, crop: crop, blend: recipe.coverBlend)
        let wholeFrame = try await WindowPlanner.measure(source: source, times: recipe.sourceTimes, blend: recipe.coverBlend)
        XCTAssertLessThan(wholeFrame.lastStep, planned.lastStep * 0.7, "the whole frame would hide half of the change")

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lw-tb-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let result = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "tb", outputDirectory: out)

        XCTAssertEqual(planned.lastStep, TailBlend.lastStepTarget, accuracy: 0.3)
        XCTAssertEqual(result.reportBeforeEncoding.lastStep, planned.lastStep, accuracy: 0.3)
        // compression adds a little to every step; on these flat synthetic halves about 0.6 (real clips: about 0.1).
        // A wrong region would read about half (see wholeFrame), far outside this.
        XCTAssertEqual(result.report.lastStep, planned.lastStep, accuracy: 0.8)
    }
}

final class TailBlendProfileTests: XCTestCase {
    private func grey(_ v: Double) -> RGB16Image {
        var img = RGB16Image(width: 16, height: 12)
        let q = UInt16(min(255, max(0, v)) * 257)
        for p in 0..<(16 * 12) { img.pixels[p * 4] = q; img.pixels[p * 4 + 1] = q; img.pixels[p * 4 + 2] = q }
        return img
    }

    /// Content that hovers far from the cover and only gets there at the end (the fireworks case, refused on the Duo)
    /// is pulled onto the given distances from the cover, frame by frame from the end; frames past the profile stay.
    func testProfileSetsEachTailFrameDistance() throws {
        var window = [40, 42, 38, 41, 39, 40, 42, 39, 41, 40].map { grey(Double($0) + 100) } + [grey(100)]
        let alphas = TailBlend.alphas(window: window, allowed: [3, 7, 12, 18])
        XCTAssertEqual(alphas.prefix(6).allSatisfy { $0 == 0 }, true)
        try TailBlend.apply(&window, alphas: alphas)
        let cover = window.last!
        let dist = window.dropLast().reversed().map { $0.meanAbsDiff(cover) }
        for (d, a) in zip(dist, [3.0, 7, 12, 18]) { XCTAssertEqual(d, a, accuracy: 0.05) }
        XCTAssertGreaterThan(dist[4], 30, "frames before the profile are left as they are")
    }
}
