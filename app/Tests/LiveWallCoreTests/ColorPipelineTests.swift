import XCTest
@testable import LiveWallCore

final class ColorPipelineTests: XCTestCase {
    func testMatrixIsTheSRGBToP3Matrix() {
        let m = ColorPipeline.srgbToP3
        let expected: [[Double]] = [[0.8224621, 0.1775380, 0], [0.0331941, 0.9668058, 0], [0.0170827, 0.0723974, 0.9105199]]
        for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(m[r][c], expected[r][c], accuracy: 2e-6, "m[\(r)][\(c)]") } }
        for r in 0..<3 { XCTAssertEqual(m[r].reduce(0, +), 1, accuracy: 1e-9, "rows keep white white") }
    }

    func testGreysAndWhiteAreUnchangedAndRedLosesSaturation() {
        var image = RGB16Image(width: 4, height: 1, pixels: [
            0, 0, 0, 0xFFFF,                                 // black
            0x8000, 0x8000, 0x8000, 0xFFFF,                  // mid grey
            0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF,                  // white
            0xFFFF, 0, 0, 0xFFFF,                            // sRGB red
        ])
        ColorPipeline.convertSRGBToDisplayP3(&image)
        for (i, v) in [0, 0x8000, 0xFFFF].enumerated() {
            for c in 0..<3 { XCTAssertEqual(Int(image.pixels[i * 4 + c]), v, accuracy: 2) }
        }
        // sRGB red expressed in P3 has R < 1 and small positive G, B (about 234, 51, 35 in 8-bit)
        let r = Double(image.pixels[12]) / 257, g = Double(image.pixels[13]) / 257, b = Double(image.pixels[14]) / 257
        XCTAssertEqual(r, 234, accuracy: 1.5)
        XCTAssertEqual(g, 51, accuracy: 1.5)
        XCTAssertEqual(b, 35, accuracy: 1.5)
        XCTAssertEqual(image.pixels[15], 0xFFFF)
    }
}
