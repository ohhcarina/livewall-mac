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
    /// The original, once `player` plays the editing copy (#0033): the copy has at most 30 frames a second, so whenever
    /// the picture rests (paused, a drag held still) this one is seeked to the exact frame and shown over it.
    private(set) var exactPlayer: AVPlayer?
    /// `exactPlayer` shows the play head's frame: the video view puts it over the copy.
    private(set) var exactShown = false
    private var exactTask: Task<Void, Never>?
    private var exactOutput: AVPlayerItemVideoOutput?
    /// `refineScrub` is inside a seek of `exactPlayer`.
    private var exactSeeking = false
    private var proxyTask: Task<Void, Never>?
    /// The editing copy for `source` is being made (or looked up): the farthest tier of the start search waits for it.
    private var copyComing = false
    /// Held while the person drags or the start search looks near the cover: the copy then pauses (`DecodeGate`). The
    /// decoder does one stream at full speed, two each at half: 11-20 on 香港天际线 (no copy yet) the smoothest start came
    /// at 36 s with the copy made alongside, at 26 s with it waiting, and the copy only 6 s later (68 s).
    private var copyGate = DecodeGate()
    /// No picture yet for the current cover (or crop): the trim bar's pictures and the copy wait for it.
    private var awaitingPreview = false {
        didSet { updateCopyGate() }
    }
    /// `runPlan` is measuring near the cover (not waiting for the copy for the farthest tier).
    private var searchingNear = false {
        didSet { updateCopyGate() }
    }
    private var planGeneration = 0
    private func updateCopyGate() { copyGate.isHeld = awaitingPreview || searchingNear || editStart != nil }
    /// Held from opening a video until its copy is made: a window behind others gets App Nap, which stretched the
    /// copy's short waits about tenfold (11-18: 44 s from the command line, over 8 minutes in the app).
    private var importActivity: NSObjectProtocol?
    private func endImportActivity() {
        if let importActivity { ProcessInfo.processInfo.endActivity(importActivity) }
        importActivity = nil
    }

    /// One answer for the toolbar button and the menu item.
    var canExport: Bool { source != nil && !isBusy && !frames.isEmpty && blockedReason == nil }

    // choices
    var rangeStart: Double = 0 { didSet { if oldValue != rangeStart { replan() } } }
    /// The start follows the cover, at the farthest still smooth point, until the person moves it themselves.
    var startIsAuto = true {
        // a start set by hand is not waiting for anything (review: the export waited, the hint stayed)
        didSet { if !startIsAuto { startIsSettling = false } }
    }
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
    /// The farthest start that still looks smooth for the current cover and crop, as far back as the search has measured
    /// so far (`searchIsComplete`; nil until the nearest tier is measured).
    var smoothStart: Double?
    /// How each start feels, 0:00 to the cover (same cover and crop as `smoothStart`), for the colour bar under the start
    /// row: bands, not two thresholds, because how far back says little about how it feels (11-18 GTA logo: 5.6 s back
    /// was smooth where 3 s back was not, and the bar said red next to a sidebar saying 平滑). Found after the plan, so
    /// it never delays the preview.
    var feelBands: [SegmentPlanner.FeelBand]?
    /// The cover that `smoothStart`, `feelBands` and `times` were worked out for; nil while a new cover's are. The trim
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
        guard let player, let item = player.currentItem, let t = scrubPending, let source else {
            scrubSeeking = false
            if !isScrubbing { detachScrubOutput() }     // the drag ended while the last seek was still running
            return
        }
        scrubPending = nil
        scrubSeeking = true
        let output: AVPlayerItemVideoOutput
        if let existing = scrubOutput, item.outputs.contains(existing) {
            output = existing
        } else {
            // attached only while scrubbing (`endScrub` removes it): playback would otherwise convert every frame for it
            output = AVPlayerItemVideoOutput(outputSettings: Self.scrubSettings(source))
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
                    if self.scrubGeneration == generation, let image {
                        self.scrubFrame = image; self.scrubShown = t
                        if self.scrubPending == nil, self.exactPlayer != nil { self.refineScrub(t, generation: generation) }
                    }
                }
                self.scrubSeeking = false
                self.chaseScrub()                   // whatever came in meanwhile, from this drag or the next one
            }
        }
    }

    private static func scrubSettings(_ source: FrameSource) -> [String: Any] {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if case .hdr = source.sourceColor {
            // tone-mapped to SDR BT.709 like the plan's frames (`FrameSource.decoderSettings`), or HLG / PQ code
            // values show washed out while dragging and jump on release (11-18 re-review)
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                  AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                  AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        return settings
    }

    /// The drag rests on `t`: the copy's picture there may be a frame or more off (it keeps 30 a second), so put the
    /// original's frame in its place (#0033: picking one exact frame).
    private func refineScrub(_ t: Double, generation: Int) {
        guard let exactPlayer, let item = exactPlayer.currentItem, let source else { return }
        let framing = (aspect: aspect, mode: mode, focus: CGPoint(x: focusX, y: focusY), area: area)
        let turns = source.quarterTurns
        exactTask?.cancel()
        exactTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, self.scrubGeneration == generation, self.scrubShown == t,
                  self.scrubPending == nil else { return }
            let output: AVPlayerItemVideoOutput
            if let existing = self.exactOutput, item.outputs.contains(existing) {
                output = existing
            } else {
                output = AVPlayerItemVideoOutput(outputSettings: Self.scrubSettings(source))
                item.add(output)
                self.exactOutput = output
            }
            let target = CMTime(seconds: t, preferredTimescale: 600)
            self.exactSeeking = true
            let finished = await exactPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            self.exactSeeking = false
            if !self.isScrubbing { self.detachExactOutput() }          // the drag ended meanwhile (see `endScrub`)
            guard finished, !Task.isCancelled, let buffer = await Self.waitForFrame(output, at: target) else { return }
            let image = await Task.detached(priority: .userInitiated) {
                Self.scrubPicture(buffer, quarterTurns: turns, aspect: framing.aspect, mode: framing.mode, focus: framing.focus,
                                  area: framing.area)
            }.value
            if self.scrubGeneration == generation, self.scrubShown == t, let image { self.scrubFrame = image }
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
        // not under a seek that is still running: its callback then never comes, `scrubSeeking` stays set and no later
        // drag shows a picture (11-19, 「设备预览画面不动」: on the 4K 240 fps original a seek takes 0.1 s, so nearly every
        // release landed in one). `chaseScrub` takes the output off when that seek is back.
        if !scrubSeeking { detachScrubOutput() }
        if !exactSeeking { detachExactOutput() }
        if !keepPicture { scrubFrame = nil }
    }

    private func detachScrubOutput() {
        guard let output = scrubOutput else { return }
        player?.currentItem?.remove(output)
        scrubOutput = nil
    }

    private func detachExactOutput() {
        guard let output = exactOutput else { return }
        exactPlayer?.currentItem?.remove(output)
        exactOutput = nil
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
    func beginEdit() {
        if editStart == nil { editStart = edit }
        updateCopyGate()
    }

    func endEdit(_ name: String) {
        guard let before = editStart else { return }
        editStart = nil
        updateCopyGate()
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
        proxyTask?.cancel()
        planTask?.cancel()
        copyGate.isHeld = false             // the old video's copy, if still being made, sees its cancellation
        copyGate = DecodeGate()
        copyComing = false
        endImportActivity()
        importActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Opening a video")
        endScrub(keepPicture: false)
        scrubSeeking = false                // a seek on the old player may never call back
        // a drag cut off without its end (gesture cancelled) must not hold back this video's plans
        editStart = nil
        replanAfterEdit = false
        awaitingPreview = true
        phase = .loading
        lastExport = nil
        openTask = Task {
            do {
                let src = try await FrameSource(url: url)
                try AutoChoices.checkDuration(src)
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
                feelBands = nil
                answeredCover = nil
                smoothKey = nil
                focusX = 0.5; focusY = 0.5
                area = Reframe.wholePicture
                chooseFit()
                suppressReplan = false
                undoManager?.removeAllActions()
                installPlayer(url)          // the original until the editing copy is ready (`makeProxy`)
                seek(to: rangeStart)
                viewMode = .lockScreen
                phase = .ready
                // the copy from the start, paused whenever the person waits for a picture or drags (`copyGate`): 11-18
                // it waited for the analysis, which starts over with every cover moved, and never came (11-19 「特别卡」)
                copyComing = true
                let gate = copyGate
                proxyTask = Task { [weak self] in
                    await self?.makeProxy(for: src, gate: gate)
                    if self?.source === src { self?.copyComing = false; self?.endImportActivity() }
                }
                replan(immediately: true)
                filmstrip = []
                // after the first picture: the decoder does one thing at a time at full speed
                while source === src, awaitingPreview, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                let strip = await PreviewImages.filmstrip(of: src.proxy?.asset ?? src.asset, to: src.duration)
                guard !Task.isCancelled else { return }        // a cancelled run returns [], which would blank the newer strip
                filmstrip = strip
            } catch {
                guard !Task.isCancelled else { return }
                endImportActivity()
                awaitingPreview = false
                phase = .failed(Self.describe(error, fallback: "无法打开这个视频。文件可能已损坏，或者格式不受支持。"))
            }
        }
    }

    /// Large or slow-to-decode videos get a small editing copy (`ProxyMaker`), made once and kept in Caches keyed by the
    /// file's path, size and date. Made while the person already edits on the original, pausing at `gate` (#0033: the
    /// decoder does one stream at full speed, two at once each at half); dragging and playback move to it when it is
    /// ready, and the start search reads its farthest tier from it.
    private func makeProxy(for src: FrameSource, gate: DecodeGate) async {
        guard await ProxyMaker.isWorthIt(src) else { return }
        guard source === src else { return }
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveWall/EditingCopies")
        let attributes = try? fm.attributesOfItem(atPath: src.url.path)
        let key = "v\(ProxyMaker.version)|\(src.url.standardizedFileURL.path)|\(attributes?[.size] ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        // the recipe's version up front: `pruneCopies` drops copies an older recipe made
        let name = "v\(ProxyMaker.version)-" + SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let copy = folder.appendingPathComponent(name + ".mov")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: copy.path) {
                // its own name: the same video reopened while a copy is being made must not share (and delete) the file
                let partial = folder.appendingPathComponent(name + "-" + UUID().uuidString + ".partial")
                defer { try? fm.removeItem(at: partial) }
                // detached, so cancel it along with this task (a new video opened)
                let job = Task.detached(priority: .userInitiated) { try await ProxyMaker.make(from: src, to: partial, gate: gate) }
                try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                try? fm.removeItem(at: copy)
                try fm.moveItem(at: partial, to: copy)
                Self.pruneCopies(in: folder, keeping: copy)
            } else {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)   // recently used
            }
            let proxy = try await FrameSource(url: copy)
            guard source === src else { return }
            src.proxy = proxy                   // the start search can use it at once
            copyComing = false
            // the players swap while nothing moves: not mid-playback or mid-drag
            while source === src, isPlaying || isScrubbing {
                try await Task.sleep(for: .milliseconds(300))
            }
            guard source === src else { return }
            switchToProxy(copy)
        } catch {
            // the copy only makes editing lighter: without it, edit the original (11-18 review)
            if !(error is CancellationError) { try? fm.removeItem(at: copy) }
        }
    }

    /// Dragging and playback move to the copy; the original's player, already on the play head, stays for exact frames.
    private func switchToProxy(_ copy: URL) {
        guard let original = player else { return }
        if let observer = timeObserver { original.removeTimeObserver(observer) }
        timeObserver = nil
        installPlayer(copy)
        player?.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        exactPlayer = original
        exactShown = true
    }

    /// Keeps the most recently used copies: at most 8, and at most `copiesLimit` bytes together (a 90 s 4K video makes
    /// about 40 MB; an 11-minute aerial at 30 fps about 0.6 GB). Copies of an older recipe (`ProxyMaker.version`) go too.
    static let copiesLimit: Int64 = 3 << 30
    private static func pruneCopies(in folder: URL, keeping current: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        // half-made copies of an app that quit or crashed meanwhile (one being made now is minutes old at most)
        for url in files where url.pathExtension == "partial" {
            if let date = try? url.resourceValues(forKeys: keys).contentModificationDate, date < Date(timeIntervalSinceNow: -3600) {
                try? fm.removeItem(at: url)
            }
        }
        for url in files where url.pathExtension == "mov" && !url.lastPathComponent.hasPrefix("v\(ProxyMaker.version)-") {
            try? fm.removeItem(at: url)
        }
        let dated = files.filter {
            $0.pathExtension == "mov" && $0 != current && $0.lastPathComponent.hasPrefix("v\(ProxyMaker.version)-")
        }.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total = Int64((try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for (index, (url, _, size)) in dated.enumerated() {
            total += size
            if index >= 7 || total > copiesLimit { try? fm.removeItem(at: url) }
        }
    }

    private func installPlayer(_ url: URL) {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player?.pause()
        isPlaying = false
        exactTask?.cancel()
        exactPlayer = nil
        exactShown = false
        exactOutput = nil
        exactSeeking = false
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
    /// `keepExact`: leave the exact picture up until the new one is there (stepping frame by frame: the copy may hold
    /// the same frame for several steps, and flashing to it in between would flicker).
    func seek(to seconds: Double, keepExact: Bool = false) {
        let t = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
        if exactPlayer != nil {
            if !keepExact { exactShown = false }
            showExact(at: t, after: keepExact ? 0 : 150)
        }
    }

    /// Seeks the original to `t` once the play head has stayed there `after` ms, then shows it over the copy.
    private func showExact(at t: Double, after ms: Int) {
        exactTask?.cancel()
        guard let exactPlayer else { return }
        exactTask = Task { [weak self] in
            if ms > 0 { try? await Task.sleep(for: .milliseconds(ms)) }
            guard !Task.isCancelled else { return }
            let finished = await exactPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            // the play head reads back through the player's clock, in 1/600 s (review 11-20: `==` almost never held)
            guard let self, finished, !Task.isCancelled, abs(self.playhead - t) <= 1.0 / 600, !self.isPlaying else { return }
            self.exactShown = true
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if playhead < rangeStart || playhead >= rangeEnd - 0.05 { seek(to: rangeStart) }
        viewMode = .source
        exactTask?.cancel()
        exactShown = false
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        let wasPlaying = isPlaying
        isPlaying = false
        // where playback stopped: the copy's frame until the original's arrives
        if wasPlaying, exactPlayer != nil { showExact(at: playhead, after: 0) }
    }

    /// Moves the play head by whole source frames (arrow keys).
    func step(frames n: Int) {
        pause()
        let fps = source?.frameRate ?? 30
        seek(to: playhead + Double(n) / max(1, fps), keepExact: true)
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
        if editStart != nil {
            replanAfterEdit = true
            planTask?.cancel()
            planWhileStartRests()
            return
        }
        notice = nil
        planTask?.cancel()
        planTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            await self?.runPlan()
        }
    }

    /// What the start search has measured for `smoothKey` so far, nearest the cover first.
    private var sweep: SegmentPlanner.StartSweep?
    /// The farthest smooth start measured when `smoothStart` was worked out: worked out again only when it moves.
    private var smoothFrom: Double?
    /// What a plan's pictures and checks depend on.
    private struct PlanKey: Equatable {
        var start, cover: Double
        var crop, area: CGRect
        var aspect, focusX, focusY: Double
        var mode: ReframeMode
    }
    private var planKey: PlanKey {
        PlanKey(start: rangeStart, cover: rangeEnd, crop: cropFraction, area: area, aspect: aspect, focusX: focusX, focusY: focusY,
                mode: mode)
    }
    /// The choices the pictures and checks shown were planned for.
    private var shownPlan: PlanKey?
    /// The pictures and checks shown are for the current choices: the export waits for this, not for the start search,
    /// which may go on further back for a while (waiting for the editing copy); the preview rests on the cover until then.
    var planIsCurrent: Bool { shownPlan != nil && shownPlan == planKey }
    /// The start search has measured back to 0:00 for this cover and worked the smoothest start out from all of it:
    /// `smoothStart` and `feelBands` are final.
    private(set) var searchIsComplete = false
    /// The picture is up with an automatic start found from the nearest 2 s; the search is still measuring the start
    /// row's 20 s, after which the start may move once, together with the colour bar appearing. The trim bar says so.
    private(set) var startIsSettling = false {
        didSet { if startIsSettling, !startIsAuto { startIsSettling = false } }
    }

    /// While the start handle is dragged on the editing copy, the plan for where it rests (200 ms still), so the frame
    /// marks and the preview are right on release, or right after (11-20, the user: 「拖动选起点之后，10帧在时间轴上的标记
    /// 没有实时跟随时间轴，过了一会锁屏又播放了一遍才好」; a new start took 2.5–4 s to plan on 香港天际线). Not on the 4K
    /// original: the drag's own seeks need the decoder there (11-18 「很卡」).
    private func planWhileStartRests() {
        guard let source, exactPlayer != nil, let sweep, !answersAreStale,
              smoothKey == SmoothKey(cover: min(rangeEnd, source.duration), crop: cropFraction) else { return }
        let cover = sweep.cover, crop = sweep.crop
        planTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            try? await self.showPlan(source: source, cover: cover, crop: crop)
        }
    }

    /// A new cover (or crop) is measured from the cover back, one tier at a time. The picture comes after the nearest 2 s;
    /// the start row's 20 s next, then the colour bar appears whole and the automatic start moves there if it has to, once,
    /// with 「正在找最顺的起点…」 shown until then (`startIsSettling`). 11-19 the start and the bar followed tier by tier,
    /// which read as the range and the bar changing by themselves (11-20); all at once after the 20 s took 14 s a cover on
    /// 香港天际线, and the user chose this. Beyond the row, from the editing copy, for when the person widens it.
    private func runPlan() async {
        guard let source else { return }
        if isExporting { needsReplan = true; return }
        // never clear an error that has not been seen; and only while a new picture is coming (one planned while the
        // start rested, or the same choices again, needs none, and nothing would set it back, review 11-20)
        if case .failed = phase {} else if !planIsCurrent { phase = .planning } else if phase == .planning { phase = .ready }
        notice = nil
        planFailed = nil
        planGeneration += 1
        let generation = planGeneration
        searchingNear = true
        defer { if planGeneration == generation { searchingNear = false } }        // not a newer run's
        do {
            let cover = min(rangeEnd, source.duration), crop = cropFraction
            let chosenCover = rangeEnd
            let key = SmoothKey(cover: cover, crop: crop)
            if smoothKey != key || sweep == nil {
                // the old cover's answers would sit in the wrong place on the colour bar meanwhile
                smoothStart = nil
                smoothFrom = nil
                feelBands = nil
                answeredCover = nil
                sweep = SegmentPlanner.StartSweep(source: source, cover: cover, crop: crop)
                smoothKey = key
                searchIsComplete = false
                startIsSettling = startIsAuto           // the hint from the moment the cover is let go
                awaitingPreview = true
            }
            guard var sweep else { return }
            var needsPlan = !planIsCurrent      // planned while the start rested (`planWhileStartRests`)
            // the start row's whole window (`SegmentPlanner.startReach` back): the automatic start, the picture and the
            // colour bar come together and stay put (11-20, the user: 「范围在很多情况下会自己变」「颜色条的出现时机也让
            // 人很奇怪，不知道什么时候会出来，出来的还是部分的」)
            let window = min(cover, SegmentPlanner.startReach)
            while true {
                // an automatic start goes to the smoothest one; a start set by hand gets its picture first, this after.
                // The first picture of a cover comes from the nearest tier (11-20, the user chose 「先出画面」: 4–6 s on
                // 香港天际线 instead of 14); the rest of the window may then move the start once, announced meanwhile
                if startIsAuto || !needsPlan {
                    let firstLook = awaitingPreview && startIsAuto
                    while firstLook ? (sweep.points.isEmpty && !sweep.isComplete) : !sweep.reached(window) {
                        while isExporting { try await Task.sleep(for: .milliseconds(250)) }    // the export decodes first
                        try await sweep.measureNextTier(source: source, copy: source.proxy)
                        try Task.checkCancellation()
                        self.sweep = sweep
                    }
                    let reach = sweep.points.prefix {
                        $0.maxStep <= SegmentPlanner.smoothStep && cover - $0.start <= SegmentPlanner.startReach + 1e-6
                    }.last?.start
                    if firstLook, !sweep.reached(window) {
                        // the first picture: the farthest smooth start of the nearest tier as it is, without the checks
                        // on the real frames (2.5–4 s more on 香港天际线); those come with the rest of the window
                        startIsSettling = true
                        smoothStart = cover > minSpan ? max(0, reach ?? cover - minSpan) : 0
                        smoothFrom = nil
                    } else if smoothStart == nil || reach != smoothFrom {
                        let found = try await SegmentPlanner.smoothestStart(source: source, sweep: sweep)
                        try Task.checkCancellation()
                        smoothStart = found
                        smoothFrom = reach
                    }
                    if startIsAuto, let smoothStart, rangeStart != smoothStart {
                        suppressReplan = true           // this is the plan for it
                        rangeStart = smoothStart
                        suppressReplan = false
                        needsPlan = true
                    }
                }
                if needsPlan {
                    try await showPlan(source: source, cover: cover, crop: crop,
                                       bands: sweep.reached(window) ? SegmentPlanner.feelBands(sweep) : nil)
                    needsPlan = false
                    answeredCover = chosenCover
                    awaitingPreview = false
                    if phase == .planning { phase = .ready }
                    // a start set by hand: the window and the smoothest start next, also when a run cut short (a drag)
                    // left the search measured but that answer not worked out (11-20: 1.97 s where it was 6.45 s)
                    continue
                }
                // the bar only whole: once the window is measured
                feelBands = sweep.reached(window) ? SegmentPlanner.feelBands(sweep) : nil
                if !sweep.reached(window) { continue }
                startIsSettling = false
                if sweep.isComplete { searchIsComplete = true; break }
                // past the window: shown only when the person widens the start row, so from the editing copy (seconds
                // instead of a minute on a long 4K video), once it is there
                searchingNear = false
                while copyComing, source.proxy == nil { try await Task.sleep(for: .milliseconds(250)) }
                while isExporting { try await Task.sleep(for: .milliseconds(250)) }
                do {
                    try await sweep.measureNextTier(source: source, copy: source.proxy)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    break       // only the bar past the start row is missing: nothing to report (review 11-20)
                }
                try Task.checkCancellation()
                self.sweep = sweep
            }
        } catch is CancellationError {
            return
        } catch {
            // keep whatever was shown before; the sidebar offers to try again
            scrubFrame = nil
            answeredCover = rangeEnd            // nothing more is coming for this cover: stop waiting for it
            awaitingPreview = false
            startIsSettling = false
            planFailed = Self.describe(error, fallback: "无法分析这一段视频。")
            phase = .ready
        }
    }

    /// Plans `rangeStart ... cover` and puts its pictures and checks up, with `bands` for the colour bar at the same
    /// moment when given.
    private func showPlan(source: FrameSource, cover: Double, crop: CGRect, bands: [SegmentPlanner.FeelBand]? = nil) async throws {
        let key = planKey
        let planned = try await SegmentPlanner.plan(source: source, start: rangeStart, cover: cover, crop: crop)
        try Task.checkCancellation()
        // at the width the plan measured them: already decoded (11-19: decoding them again at 480 took a second or two
        // of a 4K 240 fps aerial's first picture)
        let decoded = try await source.frames(at: planned.times, width: WindowPlanner.measuredWidth(crop: crop))
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
        // the plan's own cover from now on; not under a start drag held still (`planWhileStartRests`), whose picture is
        // what the person is looking at (review 11-20)
        if !isScrubbing { scrubFrame = nil }
        report = planned.report
        if let bands { feelBands = bands }
        shownPlan = key
        // also when this run is a plan made while the start rested: a run cut short may have left 分析中 up (review)
        if phase == .planning, planIsCurrent { phase = .ready }
    }

    // MARK: export

    /// Waits for a plan that is still running (the save panel can close while one does), then exports what it planned.
    func export(to packageURL: URL) {
        guard source != nil, !isExporting, blockedReason == nil else { return }
        let name = packageURL.deletingPathExtension().lastPathComponent
        let directory = packageURL.deletingLastPathComponent()
        let requested = sourceURL
        Task { [weak self] in
            // the pictures for the current choices (a newer plan may start while waiting), with the automatic start
            // settled (review 11-20: an export during 「正在找最顺的起点…」 saved the provisional one); not the search
            // past the start row
            while let self, !self.planIsCurrent || self.startIsSettling, self.planFailed == nil, self.planTask != nil,
                  self.sourceURL == requested {
                try? await Task.sleep(for: .milliseconds(100))
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
