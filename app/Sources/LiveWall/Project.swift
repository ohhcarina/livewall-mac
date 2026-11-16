import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import LiveWallCore
import Observation

/// Everything the window shows: the source, the chosen range, the planned frames and their checks.
@MainActor
@Observable
final class Project {
    enum Phase: Equatable {
        case empty
        case loading
        case ready
        case planning
        case exporting(String)
        case failed(String)
    }

    /// What the canvas shows: the result on a lock screen, or the source (to scrub, trim and frame the crop).
    enum ViewMode: String, CaseIterable, Identifiable {
        case lockScreen, source
        var id: Self { self }
    }

    var phase: Phase = .empty
    var sourceURL: URL?
    var source: FrameSource?
    var player: AVPlayer?
    var duration: Double = 0
    var playhead: Double = 0
    var isPlaying = false
    var viewMode: ViewMode = .lockScreen
    /// Evenly spaced pictures of the whole source, for the trim bar.
    var filmstrip: [CGImage] = []
    /// Bumped after each successful export so the canvas can show a short confirmation.
    var exportCount = 0
    /// Bumped to play the lock-screen animation again (like waking the phone).
    var wakeCount = 0
    /// The planned frame last picked from the trim bar, highlighted and scrolled to in the details.
    var pickedFrame: Int?

    func showFrameDetails(_ i: Int) {
        pickedFrame = i
        if i < times.count { pause(); viewMode = .source; seek(to: times[i]) }
    }

    func wake() {
        viewMode = .lockScreen
        wakeCount += 1
    }

    /// The checks said in words a non-technical user can act on.
    struct Verdict {
        enum Level { case good, caution, bad }
        var level: Level
        var title: String
        var advice: String?
    }

    /// How long a stretch the 10 frames cover, and how much faster than real time the lock screen plays it.
    var span: Double { max(0, rangeEnd - rangeStart) }
    var speedUp: Double { span / LockScreen.playSeconds }

    /// The start is earlier than the smoothest one: the bar marks that part as what makes it jumpy.
    var beyondSmooth: Bool {
        guard let smoothStart else { return false }
        return rangeStart < smoothStart - 0.02
    }

    var verdict: Verdict? {
        guard let report, let feel else { return nil }
        // the tail is pulled onto the cover, so this only happens when the mixing could not get there
        if report.lastStep > WindowAnalysis.lastStepKnownLimit {
            return Verdict(level: .bad, title: "动画可能无法开启",
                           advice: "封面前的最后一步变化过大，锁屏可能只显示静态图像。把起点往封面拖近一些。")
        }
        let back = smoothStart.map { String(format: "%.1f", max(0, rangeEnd - $0)) }
        // already at the smoothest start: nothing to drag to, say it is the content
        let fix = beyondSmooth
            ? (back.map { "想要平滑，把起点拖到绿色标记处（封面前 \($0) 秒），或点按「回到最顺的起点」。" } ?? "起点越靠近封面越顺。")
            : "这已经是这个封面最顺的取法，画面本身变化很快，手机上会看到一点跳动。"
        switch feel {
        case .flashy:
            return Verdict(level: .bad, title: "跳动明显",
                           advice: "锁屏只用约 0.75 秒播 10 帧。这一段画面变化快，相邻两帧差别很大，看起来会明显跳动。" + fix)
        case .jumpy:
            return Verdict(level: .caution, title: "略有跳动", advice: "相邻两帧差别有点大。" + fix)
        case .smooth:
            if report.reversalMean > WindowAnalysis.reversalWarning {
                return Verdict(level: .caution, title: "画面忽明忽暗",
                               advice: "这一段有地方忽明忽暗。起点越靠近封面，越不容易闪。")
            }
            return Verdict(level: .good, title: "动画平滑", advice: nil)
        }
    }

    /// Error text a user can act on: our own messages are already written for people, the system's are not.
    static func describe(_ error: Error, fallback: String) -> String {
        let text = (error as? EngineError)?.description ?? ""
        if text.contains("too short") { return "所选片段太短。请把黄色框拖宽一些。" }
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return text }
        return fallback
    }

    static func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

    /// Sends the package with AirDrop. A `.pvt` is the bundle AirDrop itself uses for Live Photos (see makelive's
    /// `--pvt`), so the iPhone saves it to Photos as a Live Photo; no iCloud Photos needed.
    /// Returns why it could not, for the caller to show (an alert on the window cannot appear over a sheet).
    @discardableResult
    func airDrop(_ url: URL) -> String? {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            return "这台 Mac 无法使用隔空投送。请在控制中心打开隔空投送，或将文件添加到「照片」。"
        }
        service.perform(withItems: [url])
        return nil
    }

    /// Opens the package with Photos, which imports it (the same as dragging it into Photos).
    @discardableResult
    func addToPhotos(_ url: URL) -> String? {
        guard let photos = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
            return "找不到「照片」App。可以在访达中找到这个文件，用隔空投送发到手机。"
        }
        NSWorkspace.shared.open([url], withApplicationAt: photos, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    /// Finished packages wait here until the person picks where they go (AirDrop, Photos or a folder): rendering
    /// first and choosing after means nothing lands on disk that nobody asked for. A package is 1-3 MB and AirDrop or
    /// the Photos import may still be reading it, so nothing is deleted while the app runs; `removeStaleExports`
    /// clears what is over a day old at launch (a second running copy keeps its fresh ones).
    static let exportsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveWall-exports", isDirectory: true)
    /// Where the person saved a copy of `lastExport`, nil until they did.
    var savedCopy: URL?
    /// `savedCopy` while that file is still there (the person may have deleted or moved it since).
    var savedFile: URL? { savedCopy.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }

    /// Called once when the app starts, never from `init` (SwiftUI may build a `Project` more than once).
    static func removeStaleExports() {
        let fm = FileManager.default
        let dayAgo = Date(timeIntervalSinceNow: -24 * 3600)
        for folder in (try? fm.contentsOfDirectory(at: exportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()      // unknown age: keep it
            if modified < dayAgo { try? fm.removeItem(at: folder) }
        }
    }

    func exportToTemporaryFolder() {
        let stem = (sourceURL?.deletingPathExtension().lastPathComponent ?? "wallpaper") + "-wallpaper"
        let folder = Self.exportsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            phase = .failed("无法在临时文件夹里做壁纸，请检查磁盘空间。")
            return
        }
        export(to: folder.appendingPathComponent(stem + ".pvt"))
    }

    /// Copies the finished package to `url` (replacing what the save panel already asked about). Returns why it could
    /// not, for the caller to show.
    @discardableResult
    func saveCopy(to url: URL) -> String? {
        guard let package = lastExport?.packageURL else { return "还没有做好的壁纸。" }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) {
                // never delete the old file before the new one is safely there
                let staging = url.deletingLastPathComponent().appendingPathComponent(".livewall-\(UUID().uuidString).pvt")
                defer { try? fm.removeItem(at: staging) }              // gone already after a successful replace
                try fm.copyItem(at: package, to: staging)
                _ = try fm.replaceItemAt(url, withItemAt: staging)
            } else {
                try fm.copyItem(at: package, to: url)
            }
            savedCopy = url
            return nil
        } catch {
            return "无法存储到这里：\(error.localizedDescription)"
        }
    }

    /// One answer for the toolbar button and the menu item.
    var canExport: Bool { source != nil && !isBusy && !frames.isEmpty && blockedReason == nil }

    // choices
    var rangeStart: Double = 0 { didSet { if oldValue != rangeStart { replan() } } }
    /// The start follows the cover, at the farthest still smooth point, until the person moves it themselves.
    var startIsAuto = true
    var rangeEnd: Double = 0 { didSet { if oldValue != rangeEnd { replan() } } }
    var preset: ScreenPreset = .iphone {
        didSet {
            guard oldValue != preset else { return }
            UserDefaults.standard.set(preset.id, forKey: "preset")
            registerUndo("更改机型") { $0.preset = oldValue }
            replan()
        }
    }
    /// For presets that turn (iPads): use the wallpaper landscape.
    var landscape = false {
        didSet {
            guard oldValue != landscape else { return }
            UserDefaults.standard.set(landscape, forKey: "landscape")
            registerUndo("更改方向") { $0.landscape = oldValue }
            replan()
        }
    }
    var customWidth: Double = 1170 { didSet { customChanged(oldValue, customWidth, key: "customWidth") } }
    var customHeight: Double = 2532 { didSet { customChanged(oldValue, customHeight, key: "customHeight") } }

    /// A typed size: at least 100 (0 or a negative number would make no picture), kept for next time.
    private func customChanged(_ old: Double, _ new: Double, key: String) {
        if new < 100 {
            if key == "customWidth" { customWidth = 100 } else { customHeight = 100 }
            return
        }
        guard old != new else { return }
        UserDefaults.standard.set(new, forKey: key)
        registerUndo("更改尺寸") { key == "customWidth" ? ($0.customWidth = old) : ($0.customHeight = old) }
        replan()
    }
    var mode: ReframeMode = .squeeze {
        didSet {
            guard oldValue != mode else { return }
            registerUndo("更改显示方式") { $0.mode = oldValue }
            replan()
        }
    }
    var focusX: Double = 0.5 { didSet { if oldValue != focusX { replan() } } }
    var focusY: Double = 0.5 { didSet { if oldValue != focusY { replan() } } }

    // results
    var times: [Double] = []
    var frames: [CGImage] = []
    var report: WindowReport?
    /// Mixing toward the cover per frame (what the export does), and how the planned stretch will feel.
    var blend: [Double] = []
    var feel: SegmentPlanner.Feel?
    /// The farthest start that still looks smooth for the current cover and crop (nil until found).
    var smoothStart: Double?
    /// The earliest start before it turns from 略有跳动 into 跳动明显 (same cover and crop as `smoothStart`), for the colour
    /// bar under the start row. Found after the plan, so it never delays the preview.
    var jumpyStart: Double?

    /// While the cover is dragged in the lock-screen view: the source frame under the pointer, framed like the
    /// wallpaper, shown on the lock screen instead of switching to the video view (11-12: the view switch jumped).
    var scrubCover: CGImage?
    /// The cover is being dragged in the lock-screen view: the preview rests on the cover and does not replay. Tied
    /// to the drag, not to `scrubCover`, which can outlive it (11-12 review).
    var isScrubbingCover = false
    private var scrubTask: Task<Void, Never>?
    private var scrubPending: Double?
    /// Bumped when a scrub ends, so a decode still running then cannot put its picture back (11-12 review).
    private var scrubGeneration = 0

    /// Shows the frame at `t` as the cover; requests while one is decoding collapse into the latest.
    func scrubCover(at t: Double) {
        scrubPending = t
        isScrubbingCover = true
        guard scrubTask == nil else { return }
        let generation = scrubGeneration
        scrubTask = Task { [weak self] in
            while let self, self.scrubGeneration == generation, let t = self.scrubPending, let source = self.source {
                self.scrubPending = nil
                guard let decoded = try? await source.frames(at: [t], width: 480), let first = decoded.first else { break }
                let plan = Reframe.plan(sourceSize: CGSize(width: first.width, height: first.height), aspect: self.aspect,
                                        mode: self.mode, focus: CGPoint(x: self.focusX, y: self.focusY))
                let image = try? await Task.detached(priority: .userInitiated) {
                    try Self.previews(decoded, plan: plan, blend: [0])
                }.value.first
                if self.scrubGeneration == generation, let image { self.scrubCover = image }
            }
            if self?.scrubGeneration == generation { self?.scrubTask = nil }
        }
    }

    /// The drag ended: the scrubbed picture stays until the new plan shows the real one (or goes now if nothing moved).
    func endScrub(coverMoved: Bool) {
        scrubGeneration += 1
        scrubTask = nil
        scrubPending = nil
        isScrubbingCover = false
        if !coverMoved { scrubCover = nil }
    }
    private var smoothKey: SmoothKey?
    private struct SmoothKey: Equatable { var cover: Double; var crop: CGRect }
    var lastExport: BuildResult?
    var notice: String?
    /// Why the last analysis failed (shown in place, with a retry), nil when it worked.
    var planFailed: String?
    /// Why this source cannot be exported (HDR and other colour spaces without a tested conversion).
    var blockedReason: String?

    private var planTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// A change came in while exporting (keys, menu, undo): plan again when the export ends.
    private var needsReplan = false
    private var timeObserver: Any?
    private var suppressReplan = false

    init() {
        // the screen and the fit are about the user's phone, not the video: keep them from last time
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "preset"), let p = ScreenPreset.all.first(where: { $0.id == id }) { preset = p }
        landscape = defaults.bool(forKey: "landscape")
        if defaults.double(forKey: "customWidth") >= 100 { customWidth = defaults.double(forKey: "customWidth") }
        if defaults.double(forKey: "customHeight") >= 100 { customHeight = defaults.double(forKey: "customHeight") }
    }

    /// Many clips fade out to black (some over their whole length), which would make a black wallpaper. When the last
    /// frame is dark next to the brightest of the last 30 s, the default cover is the last frame still at half that
    /// brightness. Clips without a fade keep their last frame.
    private static func endBeforeFadeOut(_ src: FrameSource) async -> Double {
        let d = src.duration
        guard let thumbs = try? await src.thumbnails(from: max(0, d - 30), to: d, fps: 4, width: 48), !thumbs.isEmpty else { return d }
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

    // MARK: undo

    /// The window's undo manager (set by the view).
    var undoManager: UndoManager?
    private var editStart: Edit?

    /// What a trim or crop drag changes.
    struct Edit: Equatable {
        var rangeStart, rangeEnd, focusX, focusY: Double
        var startIsAuto: Bool
    }

    private var edit: Edit {
        Edit(rangeStart: rangeStart, rangeEnd: rangeEnd, focusX: focusX, focusY: focusY, startIsAuto: startIsAuto)
    }

    private func registerUndo(_ name: String, _ undo: @escaping (Project) -> Void) {
        guard !suppressReplan, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { undo($0) }
        undoManager.setActionName(name)
    }

    private func apply(_ e: Edit, name: String) {
        let current = edit
        startIsAuto = e.startIsAuto
        rangeStart = e.rangeStart; rangeEnd = e.rangeEnd; focusX = e.focusX; focusY = e.focusY
        registerUndo(name) { $0.apply(current, name: name) }
    }

    /// Call when a drag (or key) starts changing the range or the crop, and `endEdit` when it is done: one undo step.
    func beginEdit() { if editStart == nil { editStart = edit } }

    func endEdit(_ name: String) {
        guard let before = editStart else { return }
        editStart = nil
        guard before != edit else { return }
        registerUndo(name) { $0.apply(before, name: name) }
    }

    /// How much squeezing distorts this source on this screen: 0 = none, 0.4 = squashed by 40 %.
    var squeezeDistortion: (amount: Double, horizontal: Bool) {
        guard let size = source?.size, size.height > 0 else { return (0, true) }
        let r = aspect / (size.width / size.height)
        return (1 - min(r, 1 / r), r < 1)
    }

    /// Fit the picture the way that looks right: squeeze only when it barely distorts.
    private func chooseFit() {
        mode = squeezeDistortion.amount > 0.15 ? .crop : .squeeze
    }

    var aspect: Double {
        if preset.id == "custom" { return max(0.1, customWidth) / max(0.1, customHeight) }
        return preset.rotates && landscape ? 1 / preset.aspect : preset.aspect
    }

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .planning, .exporting: return true
        default: return false
        }
    }

    // MARK: loading

    func open(_ url: URL) {
        guard !isExporting else { return }          // dropped or opened while an export is running: ignore, never swap the source under it
        // the last video asked for wins: an earlier open still loading must not write its source, range or pictures later
        openTask?.cancel()
        planTask?.cancel()
        endScrub(coverMoved: false)
        phase = .loading
        lastExport = nil
        openTask = Task {
            do {
                let src = try await FrameSource(url: url)
                if src.duration < 1.5 { throw EngineError.invalid("视频过短（\(String(format: "%.1f", src.duration)) 秒），需要至少 1.5 秒。") }
                let end = await Self.endBeforeFadeOut(src)
                // everything from here to `replan` happens at once, with no await in between
                guard !Task.isCancelled else { return }
                source = src
                if case .unsupported(let why) = src.sourceColor {
                    blockedReason = "\(why)。暂不支持这种色彩格式，无法导出。"
                } else {
                    blockedReason = nil
                }
                sourceURL = url
                NSDocumentController.shared.noteNewRecentDocumentURL(url)      // File › Open Recent, Dock menu
                duration = src.duration
                suppressReplan = true
                rangeEnd = end
                // until the smoothest start is found (the first plan sets it)
                rangeStart = max(0, end - 1)
                startIsAuto = true
                smoothStart = nil
                jumpyStart = nil
                smoothKey = nil
                focusX = 0.5; focusY = 0.5
                chooseFit()
                suppressReplan = false
                undoManager?.removeAllActions()
                installPlayer(url)
                seek(to: rangeStart)
                viewMode = .lockScreen
                phase = .ready
                replan(immediately: true)
                filmstrip = []
                let strip = await Self.filmstrip(of: src.asset, to: src.duration)
                guard !Task.isCancelled else { return }        // a cancelled run returns [], which would blank the newer strip
                filmstrip = strip
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error, fallback: "无法打开这个视频。文件可能已损坏，或者格式不受支持。"))
            }
        }
    }

    private func installPlayer(_ url: URL) {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        player?.pause()
        isPlaying = false
        let p = AVPlayer(url: url)
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playhead = t.seconds
                // like trimming in Photos / QuickTime: playback stays inside the chosen range
                if self.isPlaying, t.seconds >= self.rangeEnd - 0.001 { self.pause() }
            }
        }
        player = p
    }

    /// `count` pictures spread evenly over `start ... end` (the whole video, or the trim bar's zoomed window).
    static func filmstrip(of asset: AVAsset, from start: Double = 0, to end: Double, count: Int = 24) async -> [CGImage] {
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

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if playhead < rangeStart || playhead >= rangeEnd - 0.05 { seek(to: rangeStart) }
        viewMode = .source
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Moves the play head by whole source frames (arrow keys).
    func step(frames n: Int) {
        pause()
        let fps = source?.frameRate ?? 30
        seek(to: playhead + Double(n) / max(1, fps))
    }

    /// Shortest stretch: ten source frames (one per step).
    var minSpan: Double { 10 / max(1, source?.frameRate ?? 30) }

    func setStartToPlayhead() {
        beginEdit(); startIsAuto = false; rangeStart = max(0, min(playhead, rangeEnd - minSpan)); endEdit("设定起点")
    }

    func setEndToPlayhead() { beginEdit(); moveCover(to: playhead); endEdit("设定封面") }

    /// Moves the cover; while the start is automatic it moves along (keeping the span) until the new plan finds it.
    func moveCover(to t: Double) {
        let cover = min(duration, max(t, startIsAuto ? minSpan : rangeStart + minSpan))
        if startIsAuto { rangeStart = max(0, cover - span) }
        rangeEnd = cover
    }

    /// Back to the farthest still smooth start, and let it follow the cover again.
    func useSmoothestStart() {
        beginEdit()
        startIsAuto = true
        if let smoothStart { rangeStart = smoothStart } else { replan(immediately: true) }
        endEdit("回到最顺的起点")
    }

    var exportStep: String? { if case .exporting(let step) = phase { step } else { nil } }

    /// The crop window in the source, as fractions of its width and height (the whole picture when squeezing).
    var cropFraction: CGRect {
        guard let source else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return Reframe.plan(sourceSize: source.size, aspect: aspect, mode: mode, focus: CGPoint(x: focusX, y: focusY))
            .cropFraction(of: source.size)
    }

    // MARK: planning

    func replan(immediately: Bool = false) {
        guard source != nil, !suppressReplan else { return }
        if isExporting { needsReplan = true; return }
        notice = nil
        planTask?.cancel()
        planTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            await self?.runPlan()
        }
    }

    /// The pictures as they will play: cropped like the wallpaper and mixed toward the cover like the export.
    nonisolated private static func previews(_ decoded: [RGB16Image], plan: ReframePlan, blend: [Double]) throws -> [CGImage] {
        var previews = try decoded.map {
            try $0.resized(width: plan.coverSize.width, height: plan.coverSize.height, crop: plan.cropRect)
        }
        try TailBlend.apply(&previews, alphas: blend)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return previews.compactMap { $0.makeCGImage(colorSpace: space) }
    }

    private func runPlan() async {
        guard let source else { return }
        if isExporting { needsReplan = true; return }
        if case .failed = phase {} else { phase = .planning }     // never clear an error that has not been seen
        notice = nil
        planFailed = nil
        do {
            let cover = min(rangeEnd, source.duration), crop = cropFraction
            let key = SmoothKey(cover: cover, crop: crop)
            let newCover = smoothKey != key
            if newCover {
                let found = try await SegmentPlanner.smoothestStart(source: source, cover: cover, crop: crop)
                try Task.checkCancellation()
                smoothStart = found
                jumpyStart = nil
                smoothKey = key
            }
            if startIsAuto, let smoothStart, rangeStart != smoothStart {
                suppressReplan = true           // this is the plan for it
                rangeStart = smoothStart
                suppressReplan = false
            }
            let planned = try await SegmentPlanner.plan(source: source, start: rangeStart, cover: cover, crop: crop)
            try Task.checkCancellation()

            let width = 480
            let decoded = try await source.frames(at: planned.times, width: width)
            try Task.checkCancellation()
            let plan = Reframe.plan(sourceSize: CGSize(width: decoded[0].width, height: decoded[0].height), aspect: aspect, mode: mode,
                                    focus: CGPoint(x: focusX, y: focusY))
            // resizing and the checks are pixel loops: off the main thread, so dragging stays smooth
            let images = try await Task.detached(priority: .userInitiated) {
                try Self.previews(decoded, plan: plan, blend: planned.blend)
            }.value
            try Task.checkCancellation()
            times = planned.times
            blend = planned.blend
            feel = planned.feel
            frames = images
            scrubCover = nil                    // the plan's own cover from now on (a drag still going puts its picture back)
            report = planned.report
            if phase == .planning { phase = .ready }
            if newCover || jumpyStart == nil {
                let jumpy = try await SegmentPlanner.smoothestStart(source: source, cover: cover, crop: crop,
                                                                    ceiling: SegmentPlanner.jumpyStep)
                try Task.checkCancellation()
                jumpyStart = min(jumpy, smoothStart ?? jumpy)
            }
        } catch is CancellationError {
            return
        } catch {
            // keep whatever was shown before; the sidebar offers to try again
            scrubCover = nil
            planFailed = Self.describe(error, fallback: "无法分析这一段视频。")
            phase = .ready
        }
    }

    // MARK: export

    /// Waits for a plan that is still running (the save panel can close while one does), then exports what it planned.
    func export(to packageURL: URL) {
        guard source != nil, !isExporting, blockedReason == nil else { return }
        let name = packageURL.deletingPathExtension().lastPathComponent
        let directory = packageURL.deletingLastPathComponent()
        let requested = sourceURL
        Task { [weak self] in
            // a newer plan may start while waiting: wait for whichever is current
            while let task = self?.planTask {
                await task.value
                if self?.planTask == task { break }
            }
            guard let self else { return }
            // another video was opened meanwhile: that is what the person is doing now, drop this export quietly
            guard self.sourceURL == requested else { return }
            if case .loading = self.phase { return }
            guard let source = self.source, !self.times.isEmpty, self.planFailed == nil, !self.isBusy else {
                if !self.isExporting { self.phase = .failed(self.planFailed ?? "这一段视频还没分析完，请稍后再导出。") }
                return
            }
            self.phase = .exporting("准备中")
            var recipe = WallpaperRecipe(sourceTimes: self.times, aspect: self.aspect)
            recipe.mode = self.mode
            recipe.focus = CGPoint(x: self.focusX, y: self.focusY)
            recipe.coverBlend = self.blend
            do {
                let result = try await WallpaperBuilder.build(source: source, recipe: recipe, name: name, outputDirectory: directory) { [weak self] step in
                    Task { @MainActor in self?.phase = .exporting(step) }
                }
                self.lastExport = result
                self.savedCopy = nil
                self.exportCount += 1
                self.phase = .ready
            } catch {
                self.phase = .failed(Self.describe(error, fallback: "导出没有完成。请检查存储位置是否有足够空间，然后再试一次。"))
            }
            if self.needsReplan { self.needsReplan = false; self.replan(immediately: true) }
        }
    }
}

/// How the lock screen plays (docs/research-notes.md 一.2).
enum LockScreen {
    /// The 10 frames before the cover play forward in about this long.
    static let playSeconds = 0.75
    /// Before that, the screen goes from the cover to the first frame in about this long.
    static let returnSeconds = 0.35
}
