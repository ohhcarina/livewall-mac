// The choices the apps make for a freshly opened video before the person touches anything. Both the Mac app and the
// iOS app call these, so a rule tuned here changes both.
import CoreGraphics
import Foundation

public enum AutoChoices {
    /// Shorter clips cannot hold the 10-frame window plus a start to choose.
    public static let minimumDuration = 1.5

    public static func checkDuration(_ source: FrameSource) throws {
        if source.duration < minimumDuration {
            throw EngineError.invalid("视频过短（\(String(format: "%.1f", source.duration)) 秒），需要至少 \(minimumDuration) 秒。")
        }
    }

    /// How much squeezing distorts this source on this screen: 0 = none, 0.4 = squashed by 40 %; `horizontal` = the
    /// picture is squeezed sideways.
    public static func squeezeDistortion(sourceSize size: CGSize, aspect: Double) -> (amount: Double, horizontal: Bool) {
        guard size.height > 0 else { return (0, true) }
        let r = aspect / (size.width / size.height)
        return (1 - min(r, 1 / r), r < 1)
    }

    /// Squeeze only when it barely distorts.
    public static func fit(sourceSize size: CGSize, aspect: Double) -> ReframeMode {
        squeezeDistortion(sourceSize: size, aspect: aspect).amount > 0.15 ? .crop : .squeeze
    }

    /// Many clips fade out to black (some over their whole length), which would make a black wallpaper. When the last
    /// frame is dark next to the brightest of the last 30 s, the default cover is the last frame still at half that
    /// brightness. Clips without a fade keep their last frame. Never closer to the start than the 10-frame window plus
    /// half a second: a clip dark all through would otherwise put the cover in its first frames, with no start to choose.
    public static func coverBeforeFadeOut(_ src: FrameSource) async -> Double {
        let d = src.duration
        let earliest = min(d, 10 / max(1, src.frameRate) + 0.5)
        return max(earliest, await fadeOutCover(src))
    }

    private static func fadeOutCover(_ src: FrameSource) async -> Double {
        let d = src.duration
        guard let thumbs = try? await src.thumbnails(from: max(0, d - 30), to: d, fps: 4, width: 48, exact: false), !thumbs.isEmpty else { return d }
        let luma = thumbs.map { t -> (time: Double, value: Double) in
            let p = t.image.pixels
            var sum = 0.0
            for i in stride(from: 0, to: p.count, by: 4) { sum += Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2]) }
            return (t.time, sum / Double(p.count / 4 * 3) / 257)
        }
        let peak = luma.map(\.value).max() ?? 0
        guard let last = luma.last, peak > 24, last.value < min(30, peak * 0.35) else { return d }
        return luma.last(where: { $0.value >= peak * 0.5 })?.time ?? d
    }
}
