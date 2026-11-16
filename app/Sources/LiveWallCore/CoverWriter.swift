// Writes the Live Photo cover: a Display P3 HEIC with the Live Photo content identifier in the Apple MakerNote.
//
// The research found that a cover without a real colour profile (sips wrote `colr nclx (2,2,6)` = unspecified) makes
// iOS show the end of the wake animation through the wrong colour path ("goes teal"). The cover must carry a real
// Display P3 ICC profile (`colr prof`), like a camera's.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CoverWriter {
    /// MakerApple dictionary key that holds the asset identifier (kFigAppleMakerNote_AssetIdentifier).
    static let makerNoteAssetIdentifierKey = "17"

    /// - Parameter image: Display-P3-encoded pixels.
    public static func writeHEIC(_ image: RGB16Image, assetIdentifier: String, quality: Double = 0.92, to url: URL) throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = image.makeCGImage(colorSpace: p3) else { throw EngineError.unsupported("cannot make a CGImage") }
        try writeHEIC(cg, assetIdentifier: assetIdentifier, quality: quality, to: url)
    }

    /// - Parameter cg: must already be in Display P3 (its colour space is what gets embedded as the ICC profile).
    public static func writeHEIC(_ cg: CGImage, assetIdentifier: String, quality: Double = 0.92, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw EngineError.io("cannot create HEIC destination at \(url.path)")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyMakerAppleDictionary: [makerNoteAssetIdentifierKey: assetIdentifier],
        ]
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.io("HEIC encoding failed for \(url.path)") }
    }

    private static let ciContext = CIContext()

    /// HDR cover, the way iOS 18+ stores HDR photos: `sdr` is the base every viewer shows, `hdr` the same frame in
    /// HDR (extended range); Core Image stores the ratio as an ISO 21496-1 gain map, 10-bit Display P3. Photos shows
    /// the HDR rendition. The base is passed in rather than left to the encoder's own tone-map (which came out ~30%
    /// brighter in linear light than the system's SDR rendering of the video). `scale` multiplies both renditions in
    /// linear light.
    @available(macOS 15, *)
    public static func writeHDRHEIC(sdr: CGImage, hdr: CGImage, scale: Double = 1, assetIdentifier: String,
                                    quality: Double = 0.92, to url: URL) throws {
        // only darkening: 0 / negative has no exposure value, and above 1 the SDR base would clip while HDR does not
        guard scale > 0, scale <= 1 else { throw EngineError.invalid("HDR cover scale \(scale) is outside (0, 1]") }
        // Core Image filters work in linear light, so an exposure change of log2(scale) EV is a plain multiply
        func scaled(_ image: CGImage) -> CIImage {
            let ci = CIImage(cgImage: image)
            return scale == 1 ? ci : ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(scale)])
        }
        let base = scaled(sdr).settingProperties([
            kCGImagePropertyMakerAppleDictionary as String: [makerNoteAssetIdentifierKey: assetIdentifier],
        ])
        let data = try ciContext.heif10Representation(of: base, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [
            .hdrImage: scaled(hdr),
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ])
        try data.write(to: url, options: .atomic)
    }

    /// Content identifier stored in a HEIC (nil if the file has none).
    public static func assetIdentifier(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        return maker[makerNoteAssetIdentifierKey] as? String
    }
}
