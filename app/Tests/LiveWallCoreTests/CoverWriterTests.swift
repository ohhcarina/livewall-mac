import CoreGraphics
import ImageIO
import XCTest
@testable import LiveWallCore

final class CoverWriterTests: XCTestCase {
    func testHEICIsDisplayP3WithAnICCProfileAndTheAssetIdentifier() throws {
        var img = RGB16Image(width: 256, height: 256)
        for i in 0..<(256 * 256) { img.pixels[i * 4] = UInt16(i % 65536); img.pixels[i * 4 + 1] = 30000; img.pixels[i * 4 + 2] = 60000 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-cover-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try CoverWriter.writeHEIC(img, assetIdentifier: "11111111-2222-3333-4444-555555555555", to: url)

        XCTAssertEqual(CoverWriter.assetIdentifier(of: url), "11111111-2222-3333-4444-555555555555")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyProfileName] as? String, "Display P3")
        // a real ICC profile (`colr prof`), not the unspecified nclx (2,2,6) that made the prototype's cover look teal
        let bytes = [UInt8](try Data(contentsOf: url))
        let colr = try XCTUnwrap((0..<(bytes.count - 12)).first { bytes.fourcc($0) == "colr" })
        XCTAssertEqual(bytes.fourcc(colr + 4), "prof")
    }

    /// The HDR cover goes through Core Image, not ImageIO: the Live Photo identifier must survive it (without it
    /// Photos imports cover and video as two items), and the gain map must restore the HDR highlights.
    func testHDRCoverKeepsTheIdentifierAndCarriesAGainMap() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("HDR covers need macOS 15") }
        func flat(_ value: CGFloat, _ space: CFString, hdr: Bool) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: hdr ? 16 : 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: space)!,
                                              bitmapInfo: hdr ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                                                  : CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: space)!, components: [value, value, value, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return try XCTUnwrap(ctx.makeImage())
        }
        let sdr = try flat(0.8, CGColorSpace.displayP3, hdr: false)
        let hdr = try flat(3.0, CGColorSpace.extendedLinearDisplayP3, hdr: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-hdr-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try CoverWriter.writeHDRHEIC(sdr: sdr, hdr: hdr, assetIdentifier: "11111111-2222-3333-4444-555555555555", to: url)

        XCTAssertEqual(CoverWriter.assetIdentifier(of: url), "11111111-2222-3333-4444-555555555555")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        func linear(_ src: CGImageSource, _ options: [CFString: Any]?) throws -> Double {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary?))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16,
                                              space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Double(ctx.data!.load(as: Float.self))
        }
        let toHDR: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
        // the base is the SDR image given (0.8 encoded = ~0.6 linear), not the encoder's own tone-map of the HDR one
        XCTAssertEqual(try linear(src, nil), 0.604, accuracy: 0.03)
        XCTAssertEqual(try linear(src, toHDR), 3.0, accuracy: 0.3)

        // `scale` multiplies both renditions in linear light
        try CoverWriter.writeHDRHEIC(sdr: sdr, hdr: hdr, scale: 0.5, assetIdentifier: "11111111-2222-3333-4444-555555555555", to: url)
        let halved = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(try linear(halved, nil), 0.302, accuracy: 0.02)
        XCTAssertEqual(try linear(halved, toHDR), 1.5, accuracy: 0.15)
        XCTAssertThrowsError(try CoverWriter.writeHDRHEIC(sdr: sdr, hdr: hdr, scale: 0, assetIdentifier: "x", to: url))
    }
}
