// A 16-bit-per-channel RGBA image held in a plain array: the engine's working format.
//
// All frame maths (reframing, colour conversion, analysis) runs on this type so that the last video frame and the
// full-resolution cover go through the same code at the same precision.
import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RGB16Image {
    public let width: Int
    public let height: Int
    /// Interleaved R, G, B, A (A is always 0xFFFF), native (little) endian, no row padding.
    public var pixels: [UInt16]

    public init(width: Int, height: Int, pixels: [UInt16]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt16](repeating: 0xFFFF, count: width * height * 4))
    }

    // MARK: CVPixelBuffer (kCVPixelFormatType_64RGBALE)

    public init(pixelBuffer pb: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBALE else {
            throw EngineError.unsupported("expected a 64RGBALE pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw EngineError.unsupported("no pixel data") }
        var px = [UInt16](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * w * 8, base + y * stride, w * 8)
            }
        }
        self.init(width: w, height: h, pixels: px)
    }

    public func makePixelBuffer() throws -> CVPixelBuffer {
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBALE, attrs as CFDictionary, &pbOut)
        guard status == kCVReturnSuccess, let pb = pbOut else { throw EngineError.unsupported("CVPixelBufferCreate \(status)") }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        pixels.withUnsafeBytes { src in
            for y in 0..<height { memcpy(base + y * stride, src.baseAddress! + y * width * 8, width * 8) }
        }
        return pb
    }

    // MARK: CGImage

    public func makeCGImage(colorSpace: CGColorSpace) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                       space: colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Reads an image file (PNG/TIFF/HEIC ...) into 16-bit RGBA without colour management: the numbers in the file
    /// are the numbers you get. (`colorSpace` only tells CoreGraphics how to *interpret* them; no conversion.)
    public init(contentsOf url: URL, assumedColorSpace: CGColorSpace) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw EngineError.io("cannot read image \(url.path)")
        }
        let w = cg.width, h = cg.height
        var px = [UInt16](repeating: 0xFFFF, count: w * h * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: assumedColorSpace, bitmapInfo: info.rawValue) else { return false }
            // Re-tag the decoded image with the assumed space so drawing performs no conversion.
            let retagged = cg.copy(colorSpace: assumedColorSpace) ?? cg
            ctx.draw(retagged, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw EngineError.unsupported("cannot create a 16-bit context") }
        self.init(width: w, height: h, pixels: px)
    }

    /// 16-bit PNG, for debugging and for comparing against the research pipeline.
    public func writePNG(to url: URL, colorSpace: CGColorSpace) throws {
        guard let cg = makeCGImage(colorSpace: colorSpace),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError.io("cannot create PNG destination")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.io("PNG write failed: \(url.path)") }
    }

    // MARK: geometry

    /// Rotates clockwise by `quarterTurns` x 90 degrees (0...3): brings a frame stored sideways upright.
    public func rotated(quarterTurns: Int) -> RGB16Image {
        let q = ((quarterTurns % 4) + 4) % 4
        if q == 0 { return self }
        let outW = q == 2 ? width : height, outH = q == 2 ? height : width
        var out = [UInt16](repeating: 0xFFFF, count: outW * outH * 4)
        pixels.withUnsafeBufferPointer { srcBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                srcBuf.withMemoryRebound(to: UInt64.self) { src in            // one pixel = 4 x 16 bit = one UInt64
                    dstBuf.withMemoryRebound(to: UInt64.self) { dst in
                        for y in 0..<height {
                            for x in 0..<width {
                                let dx: Int, dy: Int
                                switch q {
                                case 1: (dx, dy) = (height - 1 - y, x)            // top-left -> top-right
                                case 2: (dx, dy) = (width - 1 - x, height - 1 - y)
                                default: (dx, dy) = (y, width - 1 - x)            // top-left -> bottom-left
                                }
                                dst[dy * outW + dx] = src[y * width + x]
                            }
                        }
                    }
                }
            }
        }
        return RGB16Image(width: outW, height: outH, pixels: out)
    }

    /// Lanczos resample (non-uniform scale allowed) of the rectangle `crop` (default: whole image) to `width x height`.
    public func resized(width newW: Int, height newH: Int, crop: CGRect? = nil) throws -> RGB16Image {
        let rect = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
        let cx = Int(rect.minX.rounded()), cy = Int(rect.minY.rounded())
        let cw = Int(rect.width.rounded()), ch = Int(rect.height.rounded())
        precondition(cx >= 0 && cy >= 0 && cx + cw <= width && cy + ch <= height, "crop outside the image")
        if cw == newW && ch == newH && cx == 0 && cy == 0 && cw == width && ch == height { return self }
        var out = [UInt16](repeating: 0xFFFF, count: newW * newH * 4)
        var error: vImage_Error = kvImageNoError
        var copy = pixels
        copy.withUnsafeMutableBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                var src = vImage_Buffer(data: srcRaw.baseAddress! + cy * width * 8 + cx * 8, height: vImagePixelCount(ch),
                                        width: vImagePixelCount(cw), rowBytes: width * 8)
                var dst = vImage_Buffer(data: dstRaw.baseAddress!, height: vImagePixelCount(newH), width: vImagePixelCount(newW),
                                        rowBytes: newW * 8)
                error = vImageScale_ARGB16U(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw EngineError.unsupported("vImageScale failed (\(error))") }
        return RGB16Image(width: newW, height: newH, pixels: out)
    }

    /// Mean absolute difference per channel on a 0...255 scale (alpha ignored). Both images must have the same size.
    public func meanAbsDiff(_ other: RGB16Image) -> Double {
        precondition(width == other.width && height == other.height)
        var sum = 0.0
        var i = 0
        let n = width * height
        for _ in 0..<n {
            sum += abs(Double(pixels[i]) - Double(other.pixels[i]))
            sum += abs(Double(pixels[i + 1]) - Double(other.pixels[i + 1]))
            sum += abs(Double(pixels[i + 2]) - Double(other.pixels[i + 2]))
            i += 4
        }
        return sum / Double(n * 3) / 257.0
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case io(String)
    case unsupported(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .io(let m), .unsupported(let m), .invalid(let m): return m
        }
    }
}
