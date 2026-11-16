import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import LiveWallCore

final class FrameSourceTests: XCTestCase {
    /// A short clip whose frames are blue with a red block in the stored top-left corner and a green strip down the
    /// stored right edge, so the stored orientation is unambiguous.
    private func writeClip(width: Int = 320, height: Int = 180, transform: CGAffineTransform = .identity,
                           codec: AVVideoCodecType = .h264, colorProperties: [String: Any]? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-fs-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if let colorProperties { settings[AVVideoColorPropertiesKey] = colorProperties }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<12 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))                    // CG origin is bottom-left
            ctx.fill(CGRect(x: 0, y: height - height / 3, width: width / 4, height: height / 3))     // stored top-left
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: width - width / 16, y: 0, width: width / 16, height: height))        // stored right edge
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private enum Dominant { case red, green, blue }

    private func dominant(_ image: RGB16Image, _ fx: Double, _ fy: Double) -> Dominant {
        let x = min(image.width - 1, Int(fx * Double(image.width))), y = min(image.height - 1, Int(fy * Double(image.height)))
        let i = (y * image.width + x) * 4
        let (r, g, b) = (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2])
        return r > g && r > b ? .red : (g > r && g > b ? .green : .blue)
    }

    private func dominant(_ cg: CGImage, _ fx: Double, _ fy: Double) -> Dominant {
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let x = min(cg.width - 1, Int(fx * Double(cg.width))), y = min(cg.height - 1, Int(fy * Double(cg.height)))
        let i = (y * cg.width + x) * 4
        return px[i] > px[i + 1] && px[i] > px[i + 2] ? .red : (px[i + 1] > px[i] && px[i + 1] > px[i + 2] ? .green : .blue)
    }

    func testFramesComeOutUprightForEveryRotation() async throws {
        for degrees in [0.0, 90, 180, 270] {
            let url = try await writeClip(transform: CGAffineTransform(rotationAngle: degrees * .pi / 180))
            let source = try await FrameSource(url: url)
            let image = try await source.frames(at: [0.2])[0]
            XCTAssertEqual(Double(image.width), Double(source.size.width), accuracy: 1, "\(degrees)°: frame must match size")
            XCTAssertEqual(Double(image.height), Double(source.size.height), accuracy: 1, "\(degrees)°")
            XCTAssertEqual(degrees == 90 || degrees == 270 ? image.height > image.width : image.width > image.height, true)

            // AVFoundation's own idea of "upright" is the ground truth for where the red block and the green strip go
            let generator = AVAssetImageGenerator(asset: source.asset)
            generator.appliesPreferredTrackTransform = true
            let truth = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            for (fx, fy) in [(0.08, 0.1), (0.95, 0.5), (0.9, 0.9), (0.08, 0.9), (0.5, 0.5), (0.92, 0.08)] {
                XCTAssertEqual(dominant(image, fx, fy), dominant(truth, fx, fy), "\(degrees)° at (\(fx), \(fy))")
            }
            // thumbnails are decoded at a reduced size and must agree too
            let thumb = try await source.frames(at: [0.2], width: 160)[0]
            XCTAssertEqual(Double(thumb.width) / Double(thumb.height), Double(image.width) / Double(image.height), accuracy: 0.03)
        }
    }

    func testSquaredSourceThroughTheWholeBuilderWhenRotated() async throws {
        // the crash in the review: a portrait clip (rotated 90°) used to trap in resized(crop:)
        let url = try await writeClip(transform: CGAffineTransform(rotationAngle: .pi / 2))
        let source = try await FrameSource(url: url)
        XCTAssertEqual(source.size.width, 180)
        XCTAssertEqual(source.size.height, 320)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lw-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        var recipe = WallpaperRecipe(sourceTimes: (0..<11).map { 0.05 + Double($0) * 0.04 }, aspect: 3222.0 / 2266.0)
        for mode in ReframeMode.allCases {
            recipe.mode = mode
            let result = try await WallpaperBuilder.build(source: source, recipe: recipe, name: "rot-\(mode.rawValue)", outputDirectory: out)
            XCTAssertEqual(Double(result.videoSize.width) / Double(result.videoSize.height), 3222.0 / 2266.0, accuracy: 0.02)
        }
    }

    func testColourTagsDecideWhatTheEngineAccepts() async throws {
        let plain = try await FrameSource(url: try await writeClip())
        XCTAssertEqual(plain.sourceColor, .sdrBT709)

        let p3 = try await FrameSource(url: try await writeClip(colorProperties: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]))
        XCTAssertEqual(p3.sourceColor, .displayP3)

        let hlg = try await FrameSource(url: try await writeClip(codec: .hevc, colorProperties: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]))
        guard case .unsupported = hlg.sourceColor else { return XCTFail("HLG must be refused, got \(hlg.sourceColor)") }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lw-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let recipe = WallpaperRecipe(sourceTimes: (0..<11).map { 0.05 + Double($0) * 0.04 }, aspect: 1.5)
        do {
            _ = try await WallpaperBuilder.build(source: hlg, recipe: recipe, name: "hlg", outputDirectory: out)
            XCTFail("an HDR source must not be exported")
        } catch {
            XCTAssertTrue("\(error)".contains("HDR"), "\(error)")
        }
    }
}

final class RotationTests: XCTestCase {
    func testQuarterTurnsMoveTheCornersTheRightWay() {
        // 3 x 2 image, every pixel distinct: value = 10 * y + x + 1 in the red channel
        var img = RGB16Image(width: 3, height: 2)
        for y in 0..<2 { for x in 0..<3 { img.pixels[(y * 3 + x) * 4] = UInt16(10 * y + x + 1) } }
        func red(_ i: RGB16Image) -> [[Int]] { (0..<i.height).map { y in (0..<i.width).map { x in Int(i.pixels[(y * i.width + x) * 4]) } } }
        XCTAssertEqual(red(img.rotated(quarterTurns: 1)), [[11, 1], [12, 2], [13, 3]])      // clockwise
        XCTAssertEqual(red(img.rotated(quarterTurns: 2)), [[13, 12, 11], [3, 2, 1]])
        XCTAssertEqual(red(img.rotated(quarterTurns: 3)), [[3, 13], [2, 12], [1, 11]])      // counter-clockwise
        XCTAssertEqual(red(img.rotated(quarterTurns: 4)), red(img))
        XCTAssertEqual(red(img.rotated(quarterTurns: -1)), red(img.rotated(quarterTurns: 3)))
    }
}
