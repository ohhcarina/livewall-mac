import CoreGraphics
import Foundation
import LiveWallCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// `--key value` options and bare positionals.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], flagNames: Set<String> = []) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if flagNames.contains(name) { flags.insert(name); i += 1; continue }
                guard i + 1 < raw.count else { fail("missing value for \(a)") }
                options[name] = raw[i + 1]
                i += 2
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func double(_ name: String) -> Double? { options[name].flatMap(Double.init) }
}

let usage = """
usage:
  livewall-cli patch <in.mov> <out.mov> --still SECONDS
  livewall-cli frames <video> --times t1,t2,... --out DIR [--size WxH] [--p3]
  livewall-cli encode <frames dir with f00.png...> <out.mov>   (P3 PNGs -> HEVC, for pipeline tests)
  livewall-cli plan <video> --start S --end E          (prints the 11 times of a decreasing-step window)
  livewall-cli check <video> --times t1,...,t11 [--width W]   (the window checks; W = decode width, default full)
  livewall-cli build <video> (--times t1,...,tN | --range S,E [--path now|even|even-blend|app|app-smooth] [--bands] [--blend] [--last-step X]) --aspect A --name NAME --out DIR [--mode squeeze|crop] [--focus X,Y] [--area X,Y,W,H] [--quality Q] [--video-zoom Z] [--max-long-side N] [--cover-quality Q]
      --path (with --range; experiments for #0017, default now): now = the App's planner (decreasing steps, calm end);
      even = 11 frames spread evenly over the range; even-blend = even, last frames mixed toward the cover so the
      last step is about --last-step (default 3); --blend mixes the same way on any path
      --blend-profile d1,d2,...: mix so the frames before the cover sit d1, d2, ... from it (second-to-last first)
      --app-blend (with --times): mix the tail toward the cover the way the App does
      --quality: VideoToolbox quality 0...1 for the video (default 0.85); --max-mbps: bitrate cap (default 40);
      --max-frame-kb: largest single frame cap in KB (default 729; this is what iOS actually refuses, research-notes 一.1)
  livewall-cli inspect <package.pvt> [--width W]   (window steps, each frame's distance to the cover and the video bitrate,
      measured on the exported video at full size unless W; for comparing device-test packages)
  livewall-cli cover <image.png sRGB-encoded> <out.heic>      (converts to Display P3, writes the HEIC)
  livewall-cli proxy <video> <out.mov>   (the App's small editing copy; build --proxy PATH plans with one)
"""

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { fail(usage) }
let args = Args(Array(raw.dropFirst()), flagNames: ["p3", "blend", "app-blend", "bands"])

func parseSize(_ s: String) -> (Int, Int) {
    let parts = s.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { fail("bad size \(s), expected WxH") }
    return (parts[0], parts[1])
}

func planTimes(_ source: FrameSource, start: Double, end: Double, crop: CGRect = WindowPlanner.fullFrame) async throws -> [Double] {
    try await WindowPlanner.plan(source: source, start: start, end: end, crop: crop)
}

do {
    switch command {
    case "patch":
        guard args.positional.count == 2, let still = args.double("still") else { fail(usage) }
        let input = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args.positional[0])))
        let output = try LivePhotoMov.prepareWallpaperVideo(input, stillImageTime: still)
        try Data(output).write(to: URL(fileURLWithPath: args.positional[1]))
        print("wrote \(args.positional[1]) (\(output.count) bytes)")

    case "frames":
        guard args.positional.count == 1, let timesArg = args.options["times"], let outDir = args.options["out"] else { fail(usage) }
        let times = timesArg.split(separator: ",").compactMap { Double($0) }
        let source = try await FrameSource(url: URL(fileURLWithPath: args.positional[0]))
        print("source: \(Int(source.size.width))x\(Int(source.size.height)) @ \(source.frameRate) fps, \(source.duration) s")
        var images = try await source.frames(at: times)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for (i, var img) in images.enumerated() {
            if let s = args.options["size"] {
                let (w, h) = parseSize(s)
                img = try img.resized(width: w, height: h)
            }
            var space = CGColorSpace(name: CGColorSpace.sRGB)!
            if args.flags.contains("p3") {
                ColorPipeline.convertSRGBToDisplayP3(&img)
                space = CGColorSpace(name: CGColorSpace.displayP3)!
            }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "f%02d.png", i))
            try img.writePNG(to: url, colorSpace: space)
            images[i] = img
        }
        print("wrote \(images.count) frames to \(outDir)")

    case "encode":
        guard args.positional.count == 2 else { fail(usage) }
        let dir = URL(fileURLWithPath: args.positional[0])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let imgs = try files.map { try RGB16Image(contentsOf: dir.appendingPathComponent($0), assumedColorSpace: p3) }
        guard !imgs.isEmpty else { fail("no .png frames in \(dir.path)") }
        let seq = Array(repeating: imgs.first!, count: WallpaperRecipe.defaultLeadFrames) + imgs
            + Array(repeating: imgs.last!, count: WallpaperRecipe.defaultTailFrames)
        try await HEVCWriter.write(frames: seq, settings: .init(width: imgs[0].width, height: imgs[0].height), to: URL(fileURLWithPath: args.positional[1]))
        print("wrote \(args.positional[1]), colr: \(String(describing: try HEVCWriter.readColorTag(of: URL(fileURLWithPath: args.positional[1]))))")

    case "plan":
        guard args.positional.count == 1, let start = args.double("start"), let end = args.double("end") else { fail(usage) }
        let source = try await FrameSource(url: URL(fileURLWithPath: args.positional[0]))
        let times = try await planTimes(source, start: start, end: end)
        print(times.map { String(format: "%.4f", $0) }.joined(separator: ","))

    case "check":
        guard args.positional.count == 1, let timesArg = args.options["times"] else { fail(usage) }
        let source = try await FrameSource(url: URL(fileURLWithPath: args.positional[0]))
        let frames = try await source.frames(at: timesArg.split(separator: ",").compactMap { Double($0) },
                                             width: args.options["width"].flatMap(Int.init))
        let r = try WindowAnalysis.analyze(frames: frames)
        print("steps \(r.stepDiffs.map { String(format: "%.1f", $0) }.joined(separator: " "))   reversal \(String(format: "%.1f", r.reversalMean))")
        for f in r.findings { print("  \(f.severity == .error ? "ERROR" : "warning"): \(f.message)") }

    case "inspect":
        // what a device round needs to compare packages that did and did not enable motion (11-11 rounds R1-R4)
        guard args.positional.count == 1 else { fail(usage) }
        let pkg = URL(fileURLWithPath: args.positional[0])
        guard let movName = try FileManager.default.contentsOfDirectory(atPath: pkg.path).first(where: { $0.hasSuffix(".mov") })
        else { fail("no .mov in \(pkg.path)") }
        let mov = pkg.appendingPathComponent(movName)
        let source = try await FrameSource(url: mov)
        let fps = 30.0, lead = WallpaperRecipe.defaultLeadFrames, count = 11
        let frames = try await source.frames(at: (0..<count).map { (Double(lead + $0) + 0.25) / fps },
                                             width: args.options["width"].flatMap(Int.init))
        let cover = frames.last!
        let steps = zip(frames.dropFirst(), frames).map { $0.meanAbsDiff($1) }
        let dist = frames.map { $0.meanAbsDiff(cover) }
        let bytes = (try FileManager.default.attributesOfItem(atPath: mov.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let maxFrame = try HEVCWriter.maxFrameBytes(of: mov) ?? 0
        print("\(pkg.lastPathComponent)  \(Int(source.size.width))x\(Int(source.size.height))  "
              + String(format: "%.1f Mbps  largest frame %d KB", bytes * 8 / source.duration / 1e6, maxFrame / 1024))
        print("  steps         " + steps.map { String(format: "%5.1f", $0) }.joined())
        print("  dist to cover " + dist.dropLast().map { String(format: "%5.1f", $0) }.joined())

    case "proxy":
        guard args.positional.count == 2 else { fail(usage) }
        let source = try await FrameSource(url: URL(fileURLWithPath: args.positional[0]))
        let t0 = Date()
        try await ProxyMaker.make(from: source, to: URL(fileURLWithPath: args.positional[1]))
        print(String(format: "editing copy in %.1f s (worth it: %@)", Date().timeIntervalSince(t0), await ProxyMaker.isWorthIt(source) ? "yes" : "no"))

    case "build":
        guard args.positional.count == 1, let aspect = args.double("aspect"),
              let name = args.options["name"], let outDir = args.options["out"] else { fail(usage) }
        let source = try await FrameSource(url: URL(fileURLWithPath: args.positional[0]))
        if let p = args.options["proxy"] { source.proxy = try await FrameSource(url: URL(fileURLWithPath: p)) }
        var recipe = WallpaperRecipe(sourceTimes: [], aspect: aspect)
        if let m = args.options["mode"] { guard let mode = ReframeMode(rawValue: m) else { fail("--mode squeeze|crop") }; recipe.mode = mode }
        if let l = args.options["max-long-side"] {
            guard let n = Int(l), n >= 16 else { fail("--max-long-side N (a whole number of pixels)") }
            recipe.maxVideoLongSide = n
        }
        if let raw = args.options["cover-quality"] {
            guard let q = Double(raw), q > 0, q <= 1 else { fail("--cover-quality Q (0 < Q <= 1)") }
            recipe.coverQuality = q
        }
        if let f = args.options["focus"] {
            let v = f.split(separator: ",").compactMap { Double($0) }
            guard v.count == 2 else { fail("--focus X,Y") }
            recipe.focus = CGPoint(x: v[0], y: v[1])
        }
        if let a = args.options["area"] {
            let v = a.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { fail("--area X,Y,W,H (fractions of the picture)") }
            recipe.area = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        if let timesArg = args.options["times"] {
            recipe.sourceTimes = timesArg.split(separator: ",").compactMap { Double($0) }
            if args.flags.contains("app-blend") {
                // the App's tail mixing on given times (to rebuild an App export from its times, 11-11 R7-1)
                let crop = Reframe.plan(sourceSize: source.size, aspect: aspect, mode: recipe.mode, focus: recipe.focus, area: recipe.area)
                    .cropFraction(of: source.size)
                let frames = try await WindowPlanner.windowFrames(source: source, times: recipe.sourceTimes, crop: crop)
                recipe.coverBlend = TailBlend.alphas(window: frames, allowed: SegmentPlanner.tailTargets(frames))
                print("  blend toward cover: " + recipe.coverBlend.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
        } else if let range = args.options["range"] {
            let v = range.split(separator: ",").compactMap { Double($0) }
            guard v.count == 2 else { fail("--range S,E") }
            // planned on the part that ends up on the wallpaper
            let crop = Reframe.plan(sourceSize: source.size, aspect: aspect, mode: recipe.mode, focus: recipe.focus, area: recipe.area)
                .cropFraction(of: source.size)
            switch args.options["path"] ?? "now" {
            case "now":
                recipe.sourceTimes = try await planTimes(source, start: v[0], end: v[1], crop: crop)
            case "even":
                recipe.sourceTimes = try PathPlanner.even(start: v[0], end: v[1])
            case "even-blend":
                recipe.sourceTimes = try PathPlanner.even(start: v[0], end: v[1])
            case "app", "app-smooth":
                // the App's planner: whole range, tail pulled onto the cover; app-smooth ignores S and starts at the
                // smoothest start for the cover E
                var start = v[0]
                if args.options["path"] == "app-smooth" {
                    let t0 = Date()
                    start = try await SegmentPlanner.smoothestStart(source: source, cover: v[1], crop: crop)
                    print(String(format: "  smoothest start %.3f (%.1f s back) in %.1f s", start, v[1] - start, Date().timeIntervalSince(t0)))
                }
                let plan = try await SegmentPlanner.plan(source: source, start: start, cover: v[1], crop: crop)
                recipe.sourceTimes = plan.times
                recipe.coverBlend = plan.blend
                print("  feel \(plan.feel)  max step \(String(format: "%.1f", plan.maxStep))"
                      + (plan.blend.contains { $0 > 0 } ? "  blend " + plan.blend.map { String(format: "%.2f", $0) }.joined(separator: " ") : ""))
                print("  times " + plan.times.map { String(format: "%.4f", $0) }.joined(separator: " "))
                if args.flags.contains("bands") {
                    // the App's colour bar under the start row, as seconds before the cover
                    for b in try await SegmentPlanner.feelBands(source: source, cover: v[1], crop: crop) {
                        print(String(format: "  bar %6.2f - %6.2f s back  ", v[1] - b.to, v[1] - b.from) + "\(b.feel)")
                    }
                }
            default:
                fail("--path now|even|even-blend|app|app-smooth")
            }
            if args.options["path"]?.hasPrefix("app") == true {
                // blend already planned
            } else if let profile = args.options["blend-profile"] {
                let frames = try await WindowPlanner.windowFrames(source: source, times: recipe.sourceTimes, crop: crop)
                recipe.coverBlend = TailBlend.alphas(window: frames, allowed: profile.split(separator: ",").compactMap { Double($0) })
                print("  blend toward cover: " + recipe.coverBlend.map { String(format: "%.2f", $0) }.joined(separator: " "))
            } else if args.options["path"] == "even-blend" || args.flags.contains("blend") {
                let frames = try await WindowPlanner.windowFrames(source: source, times: recipe.sourceTimes, crop: crop)
                recipe.coverBlend = TailBlend.alphas(window: frames, lastStepTarget: args.double("last-step") ?? TailBlend.lastStepTarget)
                print("  blend toward cover: " + recipe.coverBlend.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            print("  planned times: " + recipe.sourceTimes.map { String(format: "%.3f", $0) }.joined(separator: ","))
            let planned = try await WindowPlanner.measure(source: source, times: recipe.sourceTimes, crop: crop, blend: recipe.coverBlend)
            print("  steps (planner's measure): \(planned.stepDiffs.map { String(format: "%.1f", $0) }.joined(separator: " "))   reversal \(String(format: "%.1f", planned.reversalMean))")
        } else { fail(usage) }
        if let q = args.double("quality") { recipe.videoQuality = q }
        if let m = args.double("max-mbps") { recipe.maxVideoBitrate = m * 1e6 }
        if let kb = args.double("max-frame-kb") { guard kb > 0 else { fail("--max-frame-kb KB (> 0)") }; recipe.maxFrameBytes = Int(kb * 1024) }
        if let z = args.double("video-zoom") { guard z >= 1, z < 1.05 else { fail("--video-zoom 1...1.05") }; recipe.videoZoom = z }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let result = try await WallpaperBuilder.build(source: source, recipe: recipe, name: name, outputDirectory: URL(fileURLWithPath: outDir)) {
            print("  \($0)")
        }
        let steps = result.report.stepDiffs.map { String(format: "%.1f", $0) }.joined(separator: " ")
        let before = result.reportBeforeEncoding.stepDiffs.map { String(format: "%.1f", $0) }.joined(separator: " ")
        print("  steps (exported video): \(steps)   reversal \(String(format: "%.1f", result.report.reversalMean))")
        print("  steps (before encoding): \(before)   reversal \(String(format: "%.1f", result.reportBeforeEncoding.reversalMean))")
        for f in result.report.findings { print("  \(f.severity == .error ? "ERROR" : "warning"): \(f.message)") }
        print(String(format: "  video bitrate %.1f Mbps, largest frame %d KB, at quality %.2f", result.videoBitrate / 1e6,
                     result.maxFrameBytes / 1024, result.videoQuality))
        print("wrote \(result.packageURL.path)  video \(result.videoSize.width)x\(result.videoSize.height)  cover \(result.coverSize.width)x\(result.coverSize.height)  still-image-time \(result.stillImageTime)s")

    case "cover":
        guard args.positional.count == 2 else { fail(usage) }
        var img = try RGB16Image(contentsOf: URL(fileURLWithPath: args.positional[0]), assumedColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ColorPipeline.convertSRGBToDisplayP3(&img)
        try CoverWriter.writeHEIC(img, assetIdentifier: UUID().uuidString, to: URL(fileURLWithPath: args.positional[1]))
        print("wrote \(args.positional[1]) \(img.width)x\(img.height)")


    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
