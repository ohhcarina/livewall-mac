import AVFoundation
import CoreVideo
import XCTest
@testable import LiveWallCore

final class BitrateCapTests: XCTestCase {
    private func noiseMovie(width: Int, height: Int, frames count: Int, fps: Int = 24) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-noise-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var generator = SystemRandomNumberGenerator()
        let frames: [RGB16Image] = (0..<count).map { _ in
            var img = RGB16Image(width: width, height: height)
            for p in 0..<(width * height) {
                let v = UInt16.random(in: 20_000...45_000, using: &generator)
                img.pixels[p * 4] = v; img.pixels[p * 4 + 1] = v; img.pixels[p * 4 + 2] = v
            }
            return img
        }
        try await HEVCWriter.write(frames: frames, settings: .init(width: width, height: height, fps: fps), to: url)
        return url
    }

    /// The largest frame is what iOS refuses (rounds 34-36), and the average can stay under its cap while one keyframe
    /// is far over. The cap on the largest frame has to bite on its own.
    func testLargestFrameIsCappedEvenWhenTheAverageIsUnderItsCap() async throws {
        let source = try await FrameSource(url: try await noiseMovie(width: 320, height: 180, frames: 24))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lw-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        var recipe = WallpaperRecipe(sourceTimes: (0..<11).map { Double($0) * 0.08 }, aspect: 16.0 / 9)

        let free = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "free", outputDirectory: out)
        XCTAssertEqual(free.videoQuality, recipe.videoQuality, "the bitrate cap alone does not touch this video")
        XCTAssertGreaterThan(free.maxFrameBytes, 0)

        recipe.maxFrameBytes = free.maxFrameBytes / 2
        let capped = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "cap", outputDirectory: out)
        XCTAssertLessThanOrEqual(capped.maxFrameBytes, recipe.maxFrameBytes)
        XCTAssertLessThan(capped.videoQuality, recipe.videoQuality)
        XCTAssertLessThan(capped.videoBitrate, recipe.maxVideoBitrate)

        // the figure the builder reports is the one in the file it hands out
        let mov = capped.packageURL.appendingPathComponent("cap.mov")
        XCTAssertEqual(try HEVCWriter.maxFrameBytes(of: mov), capped.maxFrameBytes)
    }

    /// `maxFrameBytes(of:)` reads the sample table; check it against what AVAssetReader hands out for each sample.
    func testMaxFrameBytesMatchesTheSamplesTheReaderSees() async throws {
        let url = try await noiseMovie(width: 160, height: 90, frames: 14)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var largest = 0
        while let sample = output.copyNextSampleBuffer() { largest = max(largest, CMSampleBufferGetTotalSampleSize(sample)) }
        XCTAssertGreaterThan(largest, 0)
        XCTAssertEqual(try HEVCWriter.maxFrameBytes(of: url), largest)
    }

    /// 11-11 R1-R3 on the Duo: the same aurora window was refused at 72-79 Mbps and accepted at 19 Mbps; 62 Mbps
    /// (clouds) still worked. Grainy sources blow the bitrate up at a fixed quality, so the builder has to cap it.
    func testGrainyVideoIsReencodedUnderTheCap() async throws {
        let width = 320, height = 180
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-noise-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var generator = SystemRandomNumberGenerator()
        let frames: [RGB16Image] = (0..<24).map { _ in
            var img = RGB16Image(width: width, height: height)
            for p in 0..<(width * height) {
                let v = UInt16.random(in: 20_000...45_000, using: &generator)
                img.pixels[p * 4] = v; img.pixels[p * 4 + 1] = v; img.pixels[p * 4 + 2] = v
            }
            return img
        }
        try await HEVCWriter.write(frames: frames, settings: .init(width: width, height: height, fps: 24), to: url)
        let source = try await FrameSource(url: url)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lw-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        var recipe = WallpaperRecipe(sourceTimes: (0..<11).map { Double($0) * 0.08 }, aspect: 16.0 / 9)

        let uncapped = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "free", outputDirectory: out)
        recipe.maxVideoBitrate = uncapped.videoBitrate / 3
        let capped = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "cap", outputDirectory: out)
        XCTAssertLessThanOrEqual(capped.videoBitrate, recipe.maxVideoBitrate)
        XCTAssertLessThan(capped.videoQuality, recipe.videoQuality)
        XCTAssertEqual(uncapped.videoQuality, recipe.videoQuality, "under the default cap nothing changes")
    }
}
