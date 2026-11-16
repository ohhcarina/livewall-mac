// Checks of the animation window against what the device tests found (docs/research-notes.md 一.1, 一.4):
//   * the last step into the cover must be small: 1.8-5.5 worked, 5.7 did not -> stay under ~4;
//   * no region of the picture may go back and forth inside the window, or the lock screen shows a jump.
//
// Numbers are computed like the research scripts, so they are comparable with the values in the research notes:
// steps on 272 px RGB thumbnails (`research/analysis/stepdiff.py`), back-and-forth on 544 px grey thumbnails blurred
// with a 7 px box (`research/analysis/reversal.py`). The blur matters: the device problem was a REGION going dark and
// bright again (a light band sweeping over the clock); single pixels flipping, like twinkling stars or breaking foam,
// are texture and were never seen as a jump. Measured per pixel, such clips scored 20-40 and were all flagged.
import Accelerate
import Foundation

public struct WindowReport {
    public enum Severity: Int, Comparable {
        case ok, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Finding {
        public var severity: Severity
        public var message: String
    }

    /// Mean absolute difference between consecutive frames (N - 1 values).
    public var stepDiffs: [Double]
    public var lastStep: Double { stepDiffs.last ?? 0 }
    /// Mean over all pixels of min(total brightening, total darkening) inside the window, on the blurred thumbnails
    /// (see top). The approved H2 path measures 7.6 (research: 5-8), the rejected 27-40 s path about 34 (research: 36.8).
    public var reversalMean: Double
    public var reversalP99: Double
    /// Where the back-and-forth is strongest (0...1 on both axes) and how strong, on a coarse grid.
    public var hotspot: (x: Double, y: Double, value: Double)
    public var findings: [Finding]

    public var worst: Severity { findings.map(\.severity).max() ?? .ok }
}

public enum WindowAnalysis {
    /// Largest last-step difference that is known to work is 5.5 (5.7 failed); keep a margin.
    public static let lastStepComfortable = 4.0
    public static let lastStepKnownLimit = 5.5
    public static let reversalWarning = 15.0
    /// 272 px wide, like research/analysis/stepdiff.py, which the 5.5 / 5.7 thresholds were measured with.
    static let thumbnailWidth = 272
    /// Back-and-forth is measured at this width with a box blur of `reversalBlur` px, like research/analysis/reversal.py.
    static let reversalWidth = 544
    static let reversalBlur = 7

    /// Per-pixel back-and-forth of a sequence of grey images (row-major, `w` x `h`), after a box blur of `blur` px:
    /// min(total brightening, total darkening) over the sequence.
    public static func reversalMap(grey frames: [[Float]], width w: Int, height h: Int, blur: Int) -> [Float] {
        let blurred = frames.map { boxBlur($0, width: w, height: h, size: blur) }
        var up = [Float](repeating: 0, count: w * h), down = [Float](repeating: 0, count: w * h)
        for k in 1..<max(1, blurred.count) {
            for i in 0..<(w * h) {
                let d = blurred[k][i] - blurred[k - 1][i]
                if d > 0 { up[i] += d } else { down[i] -= d }
            }
        }
        return (0..<(w * h)).map { min(up[$0], down[$0]) }
    }

    /// Mean of a box filter of odd `size`, edges clamped (scipy.ndimage.uniform_filter uses mirrored edges; the
    /// difference is a few edge pixels).
    static func boxBlur(_ v: [Float], width w: Int, height h: Int, size: Int) -> [Float] {
        let r = size / 2
        guard r > 0 else { return v }
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        let n = Float(2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dx in -r...r { s += v[y * w + min(max(x + dx, 0), w - 1)] }
                tmp[y * w + x] = s / n
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dy in -r...r { s += tmp[min(max(y + dy, 0), h - 1) * w + x] }
                out[y * w + x] = s / n
            }
        }
        return out
    }

    static func grey(_ image: RGB16Image, width w: Int) throws -> (values: [Float], height: Int) {
        let h = max(1, Int((Double(image.height) / Double(image.width) * Double(w)).rounded()))
        let t = try image.resized(width: w, height: h)
        return ((0..<(w * h)).map { i in (Float(t.pixels[i * 4]) + Float(t.pixels[i * 4 + 1]) + Float(t.pixels[i * 4 + 2])) / (3 * 257) }, h)
    }

    /// - Parameter frames: the animation window in order, the last one being the cover frame (normally 11 frames).
    public static func analyze(frames: [RGB16Image]) throws -> WindowReport {
        guard frames.count >= 2 else { throw EngineError.invalid("need at least two frames") }
        let w = thumbnailWidth
        let h = max(1, Int((Double(frames[0].height) / Double(frames[0].width) * Double(w)).rounded()))
        // step differences are per-channel (the research thresholds 5.5 / 5.7 were measured that way)
        let rgb: [[Float]] = try frames.map { f in
            let t = try f.resized(width: w, height: h)
            var v = [Float](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) {
                v[i * 3] = Float(t.pixels[i * 4]) / 257
                v[i * 3 + 1] = Float(t.pixels[i * 4 + 1]) / 257
                v[i * 3 + 2] = Float(t.pixels[i * 4 + 2]) / 257
            }
            return v
        }
        var steps: [Double] = []
        for k in 1..<rgb.count {
            var sum = 0.0
            for i in 0..<(w * h * 3) { sum += Double(abs(rgb[k][i] - rgb[k - 1][i])) }
            steps.append(sum / Double(w * h * 3))
        }

        let rw = reversalWidth
        let greys = try frames.map { try grey($0, width: rw) }
        let rh = greys[0].height
        let rev = reversalMap(grey: greys.map(\.values), width: rw, height: rh, blur: reversalBlur)
        let mean = rev.reduce(0, +) / Float(rev.count)
        let p99 = rev.sorted()[min(rev.count - 1, Int(Double(rev.count) * 0.99))]

        // coarse 8 x 6 grid: strongest cell
        let gx = 8, gy = 6
        var best: (x: Double, y: Double, value: Double) = (0, 0, 0)
        for cy in 0..<gy { for cx in 0..<gx {
            var s: Float = 0, n = 0
            for y in (cy * rh / gy)..<((cy + 1) * rh / gy) { for x in (cx * rw / gx)..<((cx + 1) * rw / gx) { s += rev[y * rw + x]; n += 1 } }
            let v = Double(s) / Double(max(1, n))
            if v > best.value { best = ((Double(cx) + 0.5) / Double(gx), (Double(cy) + 0.5) / Double(gy), v) }
        } }

        var findings: [WindowReport.Finding] = []
        let last = steps.last!
        if last > lastStepKnownLimit {
            findings.append(.init(severity: .error, message: String(format: "最后一步变化 %.1f，超过实测能开启动态的上限 5.5（5.7 已不能开启）。", last)))
        } else if last > lastStepComfortable {
            findings.append(.init(severity: .warning, message: String(format: "最后一步变化 %.1f，已接近实测上限 5.5，建议压到 4 以内。", last)))
        }
        if Double(mean) > reversalWarning {
            findings.append(.init(severity: .warning, message: String(format: "窗口内有区域明暗往返（往返量 %.1f，已验收的取法约 8、被否的约 34），锁屏上会像跳动。", Double(mean))))
        }
        if frames.count != 11 {
            findings.append(.init(severity: .warning, message: "动画窗口是 \(frames.count - 1) 步；锁屏只播放封面前的 10 帧，多出或不足的部分不会按预期出现。"))
        }
        return WindowReport(stepDiffs: steps, reversalMean: Double(mean), reversalP99: Double(p99), hotspot: best, findings: findings)
    }
}
