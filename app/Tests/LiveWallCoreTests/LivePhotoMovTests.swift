import AVFoundation
import CoreGraphics
import XCTest
@testable import LiveWallCore

final class LivePhotoMovTests: XCTestCase {
    /// 22 frames of a moving gradient, encoded by the real HEVC writer.
    private func encodedClip(width: Int = 256, height: Int = 144) async throws -> URL {
        var frames: [RGB16Image] = []
        for f in 0..<22 {
            var img = RGB16Image(width: width, height: height)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                img.pixels[i] = UInt16((x * 256 + f * 1000) % 65536)
                img.pixels[i + 1] = UInt16(y * 400)
                img.pixels[i + 2] = UInt16(f * 2500)
            } }
            frames.append(img)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-test-\(UUID().uuidString).mov")
        try await HEVCWriter.write(frames: frames, settings: .init(width: width, height: height), to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEncoderKeepsTheDisplayP3ColourTag() async throws {
        let url = try await encodedClip()
        let tag = try XCTUnwrap(try HEVCWriter.readColorTag(of: url))
        XCTAssertEqual(tag.primaries, 12, "smpte432 = Display P3")
        XCTAssertEqual(tag.transfer, 1)
        XCTAssertEqual(tag.matrix, 1)
    }

    func testPatchedMovHasThreeTracksWithTheRightWiring() async throws {
        let url = try await encodedClip()
        let out = try LivePhotoMov.prepareWallpaperVideo([UInt8](try Data(contentsOf: url)), stillImageTime: 0.5)
        let top = try MovBoxes.topLevel(out)
        XCTAssertEqual(top.map(\.kind).filter { $0 == "mdat" || $0 == "moov" }, ["mdat", "moov"])
        let moov = try XCTUnwrap(top.first { $0.kind == "moov" })
        let tracks = try MovBoxes.children(out, of: moov).filter { $0.kind == "trak" }
        XCTAssertEqual(try tracks.map { try TrackFields.trackID(out, $0) }, [1, 2, 3])
        XCTAssertEqual(try tracks.map { try TrackFields.handlerType(out, $0) }, ["vide", "meta", "meta"])

        // every chunk offset points inside the mdat payload
        let mdat = try XCTUnwrap(top.first { $0.kind == "mdat" })
        for t in tracks {
            let stco = try MovBoxes.descendant(out, t, ["mdia", "minf", "stbl", "stco"])
            for i in 0..<out.be32(stco.dataOffset + 4) {
                let off = out.be32(stco.dataOffset + 8 + i * 4)
                XCTAssertTrue(off >= mdat.dataOffset && off < mdat.end, "chunk offset \(off) outside mdat")
            }
        }
        // still-image-time: leading empty edit = 0.5 s in movie units, track duration = that + the one sample
        let movieScale = try TrackFields.movieTimescale(out, moov)
        let still = tracks[2]
        let edits = try XCTUnwrap(try TrackFields.editList(out, still))
        XCTAssertEqual(edits[0].duration, movieScale / 2)
        XCTAssertEqual(edits[0].mediaTime, -1)
        XCTAssertEqual(try TrackFields.trackDuration(out, still), edits[0].duration + edits[1].duration)
        // live-photo-info has one sample per video frame
        XCTAssertEqual(try TrackFields.sampleCount(out, tracks[1]), 22)
        // next_track_ID follows the last track
        let mvhd = try MovBoxes.child(out, moov, "mvhd")
        XCTAssertEqual(out.be32(mvhd.end - 4), 4)
    }

    func testPatchingTwiceDoesNotDuplicateTracks() async throws {
        let url = try await encodedClip()
        let once = try LivePhotoMov.prepareWallpaperVideo([UInt8](try Data(contentsOf: url)), stillImageTime: 0.5)
        let twice = try LivePhotoMov.prepareWallpaperVideo(once, stillImageTime: 0.5)
        let moov = try XCTUnwrap(try MovBoxes.topLevel(twice).first { $0.kind == "moov" })
        XCTAssertEqual(try MovBoxes.children(twice, of: moov).filter { $0.kind == "trak" }.count, 3)
    }

    func testStillImageTimeOutsideTheVideoIsRejected() async throws {
        let url = try await encodedClip()
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertThrowsError(try LivePhotoMov.prepareWallpaperVideo(bytes, stillImageTime: 5))
        XCTAssertThrowsError(try LivePhotoMov.prepareWallpaperVideo(bytes, stillImageTime: -0.1))
    }

    func testAVFoundationSeesTheWallpaperMetadataTracksAndContentIdentifier() async throws {
        let url = try await encodedClip()
        let out = try LivePhotoMov.prepareWallpaperVideo([UInt8](try Data(contentsOf: url)), stillImageTime: 0.5)
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("lw-test-\(UUID().uuidString).mov")
        try Data(out).write(to: movie)
        addTeardownBlock { try? FileManager.default.removeItem(at: movie) }
        try LivePhotoIdentifier.write("ABCDEF01-2345-6789-ABCD-EF0123456789", toMovieAt: movie)

        let asset = AVURLAsset(url: movie)
        var identifiers: Set<String> = []
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            for format in try await track.load(.formatDescriptions) {
                for id in CMMetadataFormatDescriptionGetIdentifiers(format) as? [AVMetadataIdentifier] ?? [] { identifiers.insert(id.rawValue) }
            }
        }
        XCTAssertTrue(identifiers.isSuperset(of: [
            "mdta/com.apple.quicktime.live-photo-info",
            "mdta/com.apple.quicktime.live-photo-still-image-transform",
            "mdta/com.apple.quicktime.still-image-time",
        ]), "found \(identifiers)")
        let id = try await LivePhotoIdentifier.read(fromMovieAt: movie)
        XCTAssertEqual(id, "ABCDEF01-2345-6789-ABCD-EF0123456789")
        // the header rewrite must not have lost the track wiring
        let again = [UInt8](try Data(contentsOf: movie))
        let moov = try XCTUnwrap(try MovBoxes.topLevel(again).first { $0.kind == "moov" })
        XCTAssertEqual(try MovBoxes.children(again, of: moov).filter { $0.kind == "trak" }.count, 3)
        for t in try MovBoxes.children(again, of: moov) where t.kind == "trak" {
            if try TrackFields.handlerType(again, t) == "meta" {
                XCTAssertNotNil(try? MovBoxes.child(again, t, "tref"), "tref/cdsc lost by the header rewrite")
            }
        }
    }
}
