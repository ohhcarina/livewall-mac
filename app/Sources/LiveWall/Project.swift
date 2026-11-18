import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import LiveWallCore
import Observation
import SharedUI

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

    /// What the pictures on the timeline are taken from (the editing copy once there is one).
    var previewAsset: AVAsset? { source?.proxy?.asset ?? source?.asset }
    /// While the editing copy is made on import: how far along (0...1); nil otherwise.
    var proxyProgress: Double?
    private var proxyGeneration = 0

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
    /// The part of the picture kept at all (fractions of the source), set with the crop box in the video view (11-18:
    /// 「上下有黑边……没办法裁剪」). 完整 fits this part to the screen, 铺满 frames inside it.
    var area: CGRect = Reframe.wholePicture { didSet { if oldValue != area { replan() } } }
    /// Displayed size of the kept part, in source pixels.
    var areaSize: CGSize? {
        guard let s = source?.size else { return nil }
        return Reframe.areaRect(area, in: s).size
    }

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
    /// The cover that `smoothStart`, `jumpyStart` and `times` were worked out for; nil while a new cover's are. The trim
    /// bar compares it with `rangeEnd` to know when what it shows of them is stale (11-18 review: one place for
    /// dragging, waiting for the plan and a failed plan).
    var answeredCover: Double?
    var answersAreStale: Bool { answeredCover != rangeEnd }

    /// While the cover or the start is dragged in the lock-screen view: the source frame under the pointer, framed like
    /// the wallpaper, shown on the lock screen instead of switching to the video view (11-12: the view switch jumped;
    /// 11-18: dragging the start showed only the cover, 「预览窗口无法看到起点的画面」).
    var scrubFrame: CGImage?
    /// A trim handle is being dragged in the lock-screen view: the preview rests on `scrubFrame` and does not replay.
    /// Tied to the drag, not to `scrubFrame`, which can outlive it (11-12 review).
    var isScrubbing = false
    private var scrubPending: Double?
    /// The time of the last picture put on the lock screen this drag.
    private var scrubShown: Double?
    private var scrubSeeking = false
    /// Bumped when a scrub ends, so a seek still running then cannot put its picture back (11-12 review).
    private var scrubGeneration = 0
    private var scrubOutput: AVPlayerItemVideoOutput?
    /// No colour management: the plan's frames keep the decoded values and are only labelled sRGB, so the scrubbed
    /// picture must not be converted either, or the cover shifts colour on release (11-18 review).
    private nonisolated static let scrubContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Shows the frame at `t` on the lock screen. Seeks the player that is already open (hardware decoding, one seek at
    /// a time, the latest request wins), like Photos scrubbing: 11-18 a new reader per position took 0.2–0.4 s a frame
    /// on a 4K AV1 trailer with keyframes seconds apart, and dragging felt stuck (「很卡」).
    func scrub(at t: Double) {
        isScrubbing = true
        // frame by frame, most pointer events land on the frame already shown: seeking there again only waits
        if t == scrubShown, !scrubSeeking { return }
        scrubPending = t
        if !scrubSeeking { chaseScrub() }
    }

    private func chaseScrub() {
        guard let player, let item = player.currentItem, let t = scrubPending, let source else { scrubSeeking = false; return }
        scrubPending = nil
        scrubSeeking = true
        let output: AVPlayerItemVideoOutput
        if let existing = scrubOutput, item.outputs.contains(existing) {
            output = existing
        } else {
            // attached only while scrubbing (`endScrub` removes it): playback would otherwise convert every frame for it
            var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if case .hdr = source.sourceColor {
                // tone-mapped to SDR BT.709 like the plan's frames (`FrameSource.decoderSettings`), or HLG / PQ code
                // values show washed out while dragging and jump on release (11-18 re-review)
                settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            }
            output = AVPlayerItemVideoOutput(outputSettings: settings)
            item.add(output)
            scrubOutput = output
        }
        let generation = scrubGeneration
        let target = CMTime(seconds: t, preferredTimescale: 600)
        let turns = source.quarterTurns
        let framing = (aspect: aspect, mode: mode, focus: CGPoint(x: focusX, y: focusY), area: area)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                if finished, self.scrubGeneration == generation, let buffer = await Self.waitForFrame(output, at: target) {
                    let image = await Task.detached(priority: .userInitiated) {
                        Self.scrubPicture(buffer, quarterTurns: turns, aspect: framing.aspect, mode: framing.mode, focus: framing.focus,
                                          area: framing.area)
                    }.value
                    if self.scrubGeneration == generation, let image { self.scrubFrame = image; self.scrubShown = t }
                }
                self.scrubSeeking = false
                self.chaseScrub()                   // whatever came in meanwhile, from this drag or the next one
            }
        }
    }

    /// A paused player hands the frame to the output a moment after the seek; far from a keyframe in 4K that can take
    /// a while, so wait up to about a quarter of a second rather than drop the last position of a drag.
    private static func waitForFrame(_ output: AVPlayerItemVideoOutput, at time: CMTime) async -> CVPixelBuffer? {
        for _ in 0..<30 {
            if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { return buffer }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return nil
    }

    /// The frame upright (the buffer is as stored, before the track's rotation), cropped and squeezed like the
    /// wallpaper preview, 480 wide like the plan's frames. Off the main thread.
    private nonisolated static func scrubPicture(_ buffer: CVPixelBuffer, quarterTurns: Int, aspect: Double, mode: ReframeMode,
                                                 focus: CGPoint, area: CGRect) -> CGImage? {
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][((quarterTurns % 4) + 4) % 4]
        var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = image.extent.width, h = image.extent.height
        let plan = Reframe.plan(sourceSize: CGSize(width: w, height: h), aspect: aspect, mode: mode, focus: focus, area: area)
        let crop = plan.cropRect                                       // top-left origin; Core Image counts from the bottom
        let outW = 480.0, outH = (outW * Double(plan.coverSize.height) / Double(plan.coverSize.width)).rounded()
        let framed = image
            .cropped(to: CGRect(x: crop.minX, y: h - crop.maxY, width: crop.width, height: crop.height))
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -(h - crop.maxY)))
            .transformed(by: CGAffineTransform(scaleX: outW / crop.width, y: outH / crop.height))
        return scrubContext.createCGImage(framed, from: CGRect(x: 0, y: 0, width: outW, height: outH),
                                          format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The drag ended: a moved cover's picture stays until the new plan shows the real one; otherwise it goes now.
    func endScrub(keepPicture: Bool) {
        scrubGeneration += 1
        scrubPending = nil
        scrubShown = nil
        isScrubbing = false
        if let output = scrubOutput {
            player?.currentItem?.remove(output)
            scrubOutput = nil
        }
        if !keepPicture { scrubFrame = nil }
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

    // MARK: undo

    /// The window's undo manager (set by the view).
    var undoManager: UndoManager?
    private var editStart: Edit?
    /// The range or crop changed during an edit: plan once it ends. Planning while dragging decoded alongside the
    /// scrubbing and slowed both (11-18 「很卡」); the colour bar and the feel update on release, like Photos' trim.
    private var replanAfterEdit = false

    /// What a trim or crop drag changes.
    struct Edit: Equatable {
        var rangeStart, rangeEnd, focusX, focusY: Double
        var area: CGRect
        var startIsAuto: Bool
    }

    private var edit: Edit {
        Edit(rangeStart: rangeStart, rangeEnd: rangeEnd, focusX: focusX, focusY: focusY, area: area, startIsAuto: startIsAuto)
    }

    private func registerUndo(_ name: String, _ undo: @escaping (Project) -> Void) {
        guard !suppressReplan, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { undo($0) }
        undoManager.setActionName(name)
    }

    private func apply(_ e: Edit, name: String) {
        let current = edit
        startIsAuto = e.startIsAuto
        rangeStart = e.rangeStart; rangeEnd = e.rangeEnd; focusX = e.focusX; focusY = e.focusY; area = e.area
        registerUndo(name) { $0.apply(current, name: name) }
    }

    /// Call when a drag (or key) starts changing the range or the crop, and `endEdit` when it is done: one undo step.
    func beginEdit() { if editStart == nil { editStart = edit } }

    func endEdit(_ name: String) {
        guard let before = editStart else { return }
        editStart = nil
        if replanAfterEdit { replanAfterEdit = false; replan(immediately: true) }
        guard before != edit else { return }
        registerUndo(name) { $0.apply(before, name: name) }
    }

    /// How much squeezing distorts this source on this screen: 0 = none, 0.4 = squashed by 40 %.
    var squeezeDistortion: (amount: Double, horizontal: Bool) {
        guard let size = areaSize else { return (0, true) }
        return AutoChoices.squeezeDistortion(sourceSize: size, aspect: aspect)
    }

    /// Fit the picture the way that looks right: squeeze only when it barely distorts.
    private func chooseFit() {
        guard let size = areaSize else { return }
        mode = AutoChoices.fit(sourceSize: size, aspect: aspect)
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
        proxyGeneration += 1                // the cancelled import's progress updates no longer count
        let generation = proxyGeneration
        proxyProgress = nil
        planTask?.cancel()
        endScrub(keepPicture: false)
        scrubSeeking = false                // a seek on the old player may never call back
        // a drag cut off without its end (gesture cancelled) must not hold back this video's plans
        editStart = nil
        replanAfterEdit = false
        phase = .loading
        lastExport = nil
        openTask = Task {
            do {
                let src = try await FrameSource(url: url)
                try AutoChoices.checkDuration(src)
                do {
                    try await attachProxy(to: src, generation: generation)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // the copy only makes editing lighter: without it, edit the original (11-18 review)
                    if proxyGeneration == generation { proxyProgress = nil }
                    src.proxy = nil
                }
                let end = await AutoChoices.coverBeforeFadeOut(src)
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
                answeredCover = nil
                smoothKey = nil
                focusX = 0.5; focusY = 0.5
                area = Reframe.wholePicture
                chooseFit()
                suppressReplan = false
                undoManager?.removeAllActions()
                installPlayer(src.proxy?.url ?? url)          // scrubbing and playback on the editing copy
                seek(to: rangeStart)
                viewMode = .lockScreen
                phase = .ready
                replan(immediately: true)
                filmstrip = []
                let strip = await PreviewImages.filmstrip(of: src.proxy?.asset ?? src.asset, to: src.duration)
                guard !Task.isCancelled else { return }        // a cancelled run returns [], which would blank the newer strip
                filmstrip = strip
            } catch {
                guard !Task.isCancelled else { return }          // a newer open owns the progress bar now
                proxyProgress = nil
                phase = .failed(Self.describe(error, fallback: "无法打开这个视频。文件可能已损坏，或者格式不受支持。"))
            }
        }
    }

    /// Large or slow-to-decode videos get a small editing copy (`ProxyMaker`), made once and kept in Caches keyed by the
    /// file's path, size and date (11-18, 「导入可以久一些」: ~6 s for a 90 s 4K AV1 trailer, then every edit is light).
    private func attachProxy(to src: FrameSource, generation: Int) async throws {
        guard await ProxyMaker.isWorthIt(src) else { return }
        try Task.checkCancellation()
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveWall/EditingCopies")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let attributes = try? fm.attributesOfItem(atPath: src.url.path)
        let key = "v\(ProxyMaker.version)|\(src.url.standardizedFileURL.path)|\(attributes?[.size] ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let copy = folder.appendingPathComponent(name + ".mov")
        // the progress bar belongs to the newest import only (`proxyGeneration` is bumped by `open`)
        let current = { [weak self] in self?.proxyGeneration == generation }
        if !fm.fileExists(atPath: copy.path) {
            if current() { proxyProgress = 0 }
            // its own name: the same video reopened while a copy is being made must not share (and delete) the file
            let partial = folder.appendingPathComponent(name + "-" + UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: partial) }
            try await ProxyMaker.make(from: src, to: partial) { p in
                Task { @MainActor [weak self] in
                    if let self, self.proxyGeneration == generation, self.proxyProgress != nil { self.proxyProgress = p }
                }
            }
            try Task.checkCancellation()
            try? fm.removeItem(at: copy)
            try fm.moveItem(at: partial, to: copy)
            Self.pruneCopies(in: folder, keeping: copy)
        } else {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)   // recently used
        }
        if current() { proxyProgress = nil }
        do {
            src.proxy = try await FrameSource(url: copy)
        } catch {
            try? fm.removeItem(at: copy)        // a broken copy (disk full, cut short) is made again next time
            throw error
        }
    }

    /// Keeps the 8 most recently used copies (a 90 s 4K video makes about 40 MB).
    private static func pruneCopies(in folder: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.filter { $0.pathExtension == "mov" && $0 != current }.map {
            ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(7) { try? fm.removeItem(at: url) }
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

    /// Moves the cover. `keeping` a span (dragging the cover, 11-18: 「拖动封面应该是固定时长整块移动吧」) moves the start
    /// along with it, set by hand or not; otherwise (the O key, VoiceOver) a start set by hand stays, like an out point.
    /// An automatic start always moves along until the new plan finds it.
    func moveCover(to t: Double, keeping span: Double? = nil) {
        let follows = startIsAuto || span != nil
        let cover = min(duration, max(t, follows ? minSpan : rangeStart + minSpan))
        if follows { rangeStart = max(0, cover - max(minSpan, span ?? self.span)) }
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
        return Reframe.plan(sourceSize: source.size, aspect: aspect, mode: mode, focus: CGPoint(x: focusX, y: focusY), area: area)
            .cropFraction(of: source.size)
    }

    // MARK: planning

    func replan(immediately: Bool = false) {
        guard source != nil, !suppressReplan else { return }
        if isExporting { needsReplan = true; return }
        if editStart != nil { replanAfterEdit = true; planTask?.cancel(); return }
        notice = nil
        planTask?.cancel()
        planTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            await self?.runPlan()
        }
    }

    private func runPlan() async {
        guard let source else { return }
        if isExporting { needsReplan = true; return }
        if case .failed = phase {} else { phase = .planning }     // never clear an error that has not been seen
        notice = nil
        planFailed = nil
        do {
            let cover = min(rangeEnd, source.duration), crop = cropFraction
            let chosenCover = rangeEnd
            let key = SmoothKey(cover: cover, crop: crop)
            let newCover = smoothKey != key
            if newCover {
                // the old cover's answers would sit in the wrong place on the colour bar meanwhile; and forget whose
                // they were, or a cancelled run here would leave them nil for good when that cover comes back (undo)
                smoothStart = nil
                jumpyStart = nil
                smoothKey = nil
                answeredCover = nil
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
                                    focus: CGPoint(x: focusX, y: focusY), area: area)
            // resizing and the checks are pixel loops: off the main thread, so dragging stays smooth
            let images = try await Task.detached(priority: .userInitiated) {
                try PreviewImages.wallpaper(decoded, plan: plan, blend: planned.blend)
            }.value
            try Task.checkCancellation()
            times = planned.times
            blend = planned.blend
            feel = planned.feel
            frames = images
            scrubFrame = nil                    // the plan's own cover from now on (a drag still going puts its picture back)
            report = planned.report
            if phase == .planning { phase = .ready }
            if newCover || jumpyStart == nil {
                let jumpy = try await SegmentPlanner.smoothestStart(source: source, cover: cover, crop: crop,
                                                                    ceiling: SegmentPlanner.jumpyStep)
                try Task.checkCancellation()
                jumpyStart = min(jumpy, smoothStart ?? jumpy)
            }
            answeredCover = chosenCover
        } catch is CancellationError {
            return
        } catch {
            // keep whatever was shown before; the sidebar offers to try again
            scrubFrame = nil
            answeredCover = rangeEnd            // nothing more is coming for this cover: stop waiting for it
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
            recipe.area = self.area
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
