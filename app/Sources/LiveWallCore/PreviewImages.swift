// Pictures the apps show before anything is exported: the wallpaper's frames as they will play, and a filmstrip.
import AVFoundation
import CoreGraphics
import Foundation

public enum PreviewImages {
    /// The pictures as they will play: cropped like the wallpaper and mixed toward the cover like the export.
    /// Pixel loops: call it off the main thread.
    public static func wallpaper(_ decoded: [RGB16Image], plan: ReframePlan, blend: [Double]) throws -> [CGImage] {
        var previews = try decoded.map {
            try $0.resized(width: plan.coverSize.width, height: plan.coverSize.height, crop: plan.cropRect)
        }
        try TailBlend.apply(&previews, alphas: blend)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return previews.compactMap { $0.makeCGImage(colorSpace: space) }
    }

    /// `count` small frames spread evenly over `start ... end` (each from the middle of its slot).
    public static func filmstrip(of asset: AVAsset, from start: Double = 0, to end: Double, count: Int = 24) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let slack = CMTime(seconds: min(0.5, (end - start) / Double(count) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var images: [CGImage] = []
        for i in 0..<count {
            if Task.isCancelled { return [] }
            let t = start + (end - start) * (Double(i) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(image) }
        }
        return images
    }
}
