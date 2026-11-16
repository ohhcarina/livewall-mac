// Colour conversion for the wallpaper video and cover.
//
// The research pipeline (docs/research-notes.md 一.3) treats the source's gamma-encoded RGB as sRGB-encoded, converts
// it to Display P3 with the *same appearance*, and then tags video and cover as Display P3 — that is what was verified
// on the device. Display P3 uses the sRGB transfer curve, so the conversion is: decode curve -> 3x3 matrix in linear
// light -> encode curve. This file is the single implementation of it (the prototype had two copies).
import Foundation

public enum ColorPipeline {
    // MARK: matrix from the primaries (both spaces are D65, no chromatic adaptation needed)

    private typealias M3 = [[Double]]

    private static func rgbToXYZ(r: (Double, Double), g: (Double, Double), b: (Double, Double), white: (Double, Double)) -> M3 {
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let cols = [xyz(r), xyz(g), xyz(b)]
        let m: M3 = (0..<3).map { row in (0..<3).map { col in cols[col][row] } }
        let w = xyz(white)
        let s = solve(m, w)
        return (0..<3).map { row in (0..<3).map { col in m[row][col] * s[col] } }
    }

    private static func det(_ m: M3) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    private static func solve(_ m: M3, _ v: [Double]) -> [Double] {      // Cramer's rule
        let d = det(m)
        return (0..<3).map { i in
            var mi = m
            for r in 0..<3 { mi[r][i] = v[r] }
            return det(mi) / d
        }
    }

    private static func inverse(_ m: M3) -> M3 {
        (0..<3).map { col in
            let unit = (0..<3).map { $0 == col ? 1.0 : 0.0 }
            return solve(m, unit)
        }.transposed()
    }

    private static func multiply(_ a: M3, _ b: M3) -> M3 {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    /// Linear sRGB -> linear Display P3.
    static let srgbToP3: [[Double]] = {
        let d65 = (0.3127, 0.3290)
        let srgb = rgbToXYZ(r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060), white: d65)
        let p3 = rgbToXYZ(r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060), white: d65)
        return multiply(inverse(p3), srgb)
    }()

    // MARK: transfer curve (sRGB / Display P3 share it)

    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static let decodeLUT: [Float] = (0..<65536).map { Float(decode(Double($0) / 65535)) }
    private static let encodeLUT: [UInt16] = (0..<65536).map { UInt16(min(65535, max(0, (encode(Double($0) / 65535) * 65535).rounded()))) }

    /// sRGB-encoded -> Display-P3-encoded values (same appearance), in place.
    public static func convertSRGBToDisplayP3(_ image: inout RGB16Image) {
        let m = srgbToP3.map { $0.map { Float($0) } }
        let (m00, m01, m02, m10, m11, m12, m20, m21, m22) = (m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2])
        let dec = decodeLUT, enc = encodeLUT
        let count = image.width * image.height
        image.pixels.withUnsafeMutableBufferPointer { px in
            dec.withUnsafeBufferPointer { dec in
                enc.withUnsafeBufferPointer { enc in
                    var i = 0
                    for _ in 0..<count {
                        let r = dec[Int(px[i])], g = dec[Int(px[i + 1])], b = dec[Int(px[i + 2])]
                        let pr = min(1, max(0, m00 * r + m01 * g + m02 * b))
                        let pg = min(1, max(0, m10 * r + m11 * g + m12 * b))
                        let pb = min(1, max(0, m20 * r + m21 * g + m22 * b))
                        px[i] = enc[Int(pr * 65535 + 0.5)]
                        px[i + 1] = enc[Int(pg * 65535 + 0.5)]
                        px[i + 2] = enc[Int(pb * 65535 + 0.5)]
                        i += 4
                    }
                }
            }
        }
    }
}

private extension Array where Element == [Double] {
    func transposed() -> [[Double]] { (0..<3).map { j in (0..<3).map { i in self[i][j] } } }
}
