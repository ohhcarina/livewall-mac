import LiveWallCore
import SharedUI
import SwiftUI

/// The timeline in two rows, in the order people decide (11-12, the user picked this from three mock-ups in
/// `_archive/_handoff/1111-时间轴三版.html`):
/// 1. 选封面 — the whole video; pointing anywhere puts the cover (where the animation stops) there.
/// 2. 选起点 — the seconds before the cover, enlarged so even a fraction of a second can be dragged, with the start
///    handle. The colour bar under it says how the animation feels for a start at each place (hover for the words).
struct TrimBar: View {
    @Bindable var project: Project

    private let coverHeight: CGFloat = 34
    private let startHeight: CGFloat = 44
    private let tickArea: CGFloat = 14
    private let zoneHeight: CGFloat = 6
    private let zoneGap: CGFloat = 5
    private let handleWidth: CGFloat = 14

    private enum Drag { case cover, start }
    @State private var dragging: Drag?
    /// Whether the drag started in the lock-screen view, and where the cover was then.
    @State private var fromLock = false
    @State private var coverAtBegin: Double?
    /// The stretch's length when the drag began: the cover drags the whole stretch (it shrinks only against 0:00).
    @State private var spanAtBegin: Double = 0
    /// Fine scrubbing (11-18, 「最好跟系统相册的编辑一样，能够在长按的时候精确控制」「应该同时放大时间轴」): holding the
    /// cover still for a moment zooms the cover row in on the seconds around it, `pointsPerFrame` per source frame, with
    /// the cover staying under the pointer; it zooms back out when the button goes up. The window shown while zoomed.
    @State private var fine: ClosedRange<Double>?
    /// Pictures for the zoomed window (the whole-video strip is far too coarse there).
    @State private var fineStrip: (window: ClosedRange<Double>, images: [CGImage])?
    @State private var holdTimer: Task<Void, Never>?
    /// Where the pointer was when the current wait for a hold began, and where it is now.
    @State private var holdX: CGFloat = 0
    @State private var lastX: CGFloat = 0
    @State private var coverRowWidth: CGFloat = 1
    private let pointsPerFrame: CGFloat = 8
    /// The start row's window, held still while the start is dragged: the scale must not change under the pointer.
    @State private var frozenWindow: ClosedRange<Double>?
    /// While the cover is dragged: how many seconds the start row shows, held so the row slides with the cover and keeps
    /// its scale (11-18: it used to squeeze as the cover moved, measured from the old plan's starts —
    /// 「底下不管怎么样都应该是固定的」).
    @State private var coverDragWidth: Double?
    /// The cover is dragged, or its plan has not answered yet (or failed): what the start row has of the last plan
    /// belongs to another cover. `Project.answeredCover` knows; no guessing here (11-18 review).
    private var coverIsMoving: Bool { dragging == .cover || project.answersAreStale }
    /// Finer pictures for the start row (the whole-video strip has too few to fill it).
    @State private var zoomStrip: (window: ClosedRange<Double>, images: [CGImage])?
    @State private var barHovered = false
    /// The planned frame the pointer is over (bubble with its picture). `LIVEWALL_STATE=tick` shows one, for screenshots.
    @State private var hoverTick: Int? = ProcessInfo.processInfo.environment["LIVEWALL_STATE"]?.contains("tick") == true ? 3 : nil
    /// Where the pointer is on the colour bar, as a fraction of its width. `LIVEWALL_STATE=skip` shows one.
    @State private var hoverZone: Double? = ProcessInfo.processInfo.environment["LIVEWALL_STATE"]?.contains("skip") == true ? 0.12 : nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            playButton
            VStack(alignment: .leading, spacing: 5) {
                title("选封面") { coverLabel }
                // lined up with the start row's pictures (its handle sits left of them)
                coverRow.frame(height: coverHeight).padding(.leading, handleWidth).padding(.trailing, 3)
                title("选起点") {
                    Text(String(format: "封面前 %.1f 秒 · %.1f× 快放", project.span, project.speedUp)).monospacedDigit()
                        .help("锁屏只用约 0.75 秒播这一整段，所以是快放")
                }
                .padding(.top, 6)
                startRow.frame(height: tickArea + startHeight + zoneGap + zoneHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 22)
        .onHover { barHovered = $0 && !SnapshotHook.scripted }
        // another video: a drag cut off without its end (gesture cancelled) must not carry over (11-18 re-review)
        .task(id: fine) {
            guard let window = fine, let asset = project.previewAsset else { return }
            if fineStrip != nil { try? await Task.sleep(for: .milliseconds(150)) }      // panning: once it settles
            if Task.isCancelled { return }
            let images = await PreviewImages.filmstrip(of: asset, from: window.lowerBound, to: window.upperBound, count: 12)
            if !Task.isCancelled, !images.isEmpty { withAnimation(.easeOut(duration: 0.2)) { fineStrip = (window, images) } }
        }
        .onChange(of: coverIsMoving) {
            // the new cover's answers are in: the start row may take its own width again, in one move
            guard !coverIsMoving, coverDragWidth != nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { coverDragWidth = nil }
        }
        .onChange(of: project.sourceURL) {
            holdTimer?.cancel(); holdTimer = nil
            fine = nil; fineStrip = nil; dragging = nil; frozenWindow = nil; coverDragWidth = nil
        }
    }

    private func title(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(text).fontWeight(.semibold)
            Spacer()
            trailing().foregroundStyle(.secondary)
        }
        .font(.caption)
        .opacity((dragging != nil && fine == nil) || project.isPlaying ? 0.5 : 1)
    }

    /// The cover is what the lock screen shows most of the time: its picture, not just its time.
    private var coverLabel: some View {
        HStack(spacing: 6) {
            if let cover = project.frames.last {
                Image(decorative: cover, scale: 1).resizable()
                    .aspectRatio(project.aspect, contentMode: .fill)
                    .frame(width: 16 * CGFloat(project.aspect), height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.yellow, lineWidth: 1.5))
            }
            if fine != nil {
                Text("逐帧").font(.caption2.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.yellow, in: Capsule())
                    .transition(.opacity)
            }
            Text("封面 " + clock(project.rangeEnd, precise: fine != nil)).monospacedDigit()
        }
        .help("动画停在这一帧，也是锁屏平时的画面。拖动时按住不动片刻可以逐帧微调")
    }

    /// In lock-screen mode the button wakes the (simulated) phone; in source mode it plays the chosen range.
    private var playButton: some View {
        let lock = project.viewMode == .lockScreen
        return Button {
            if lock { project.wake() } else { project.togglePlay() }
        } label: {
            // a plain circle: the bar itself is the glass, no glass on glass
            Image(systemName: !lock && project.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lock ? "播放锁屏动画" : (project.isPlaying ? "暂停" : "播放"))
        .help(lock ? "播放锁屏动画（空格键）" : (project.isPlaying ? "暂停（空格键）" : "播放所选片段（空格键）"))
    }

    // MARK: row 1, the cover

    private var coverRow: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let total = max(project.duration, 0.001)
            let shown = fine ?? 0...total
            let span = max(0.001, shown.upperBound - shown.lowerBound)
            let x = { (t: Double) -> CGFloat in CGFloat((t - shown.lowerBound) / span) * w }
            let time = { (px: CGFloat) -> Double in shown.lowerBound + Double(min(max(0, px / w), 1)) * span }
            let startX = x(project.rangeStart), endX = x(project.rangeEnd)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    // the whole-video strip, stretched with the zoom (that is the transition), finer pictures over it
                    if fine == nil {
                        filmstrip(project.filmstrip, width: w, height: coverHeight).transition(.opacity)
                    } else {
                        // zoomed: the loading strip under the window's own pictures, which lag a moment while it pans,
                        // never the coarse pictures stretched huge (11-18 review)
                        LoadingStrip(slots: 12).frame(width: w, height: coverHeight).transition(.opacity)
                        if let strip = fineStrip, strip.window.overlaps(shown) {
                            filmstrip(strip.images, width: x(strip.window.upperBound) - x(strip.window.lowerBound), height: coverHeight)
                                .offset(x: x(strip.window.lowerBound))
                                .transition(.opacity)
                        }
                    }
                    if fine != nil { frameTicks(shown: shown, width: w) }
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, startX), height: coverHeight)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, w - endX), height: coverHeight).offset(x: endX)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.yellow.opacity(0.9), lineWidth: 2)
                        .frame(width: max(4, endX - startX + 2), height: coverHeight)
                        .offset(x: min(startX - 1, endX - 3))
                }
                .frame(width: w, height: coverHeight, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)

                // the cover: a tall yellow pin
                Capsule().fill(Color.yellow).frame(width: 4, height: coverHeight + 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: endX - 2, y: -4)
                    .allowsHitTesting(false)
                playhead(at: x(project.playhead), height: coverHeight)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil { begin(.cover) }
                    let px = g.location.x
                    let previousX = lastX
                    lastX = px
                    // drift since the wait began, not per event: a slow steady drag is not a hold (11-18 review)
                    if fine == nil, holdTimer == nil || abs(px - holdX) > 3 { holdStill(at: px) }
                    if let window = fine {
                        // on the zoomed row, snapped to whole source frames; past either end the window pans along,
                        // so frame by frame goes on as far as the drag does (11-18 review)
                        let fps = max(1, project.source?.frameRate ?? 30)
                        // past an end, the window pans by how far the pointer moved this time (not by how far out it is,
                        // which ran away while held there), never past the video, and only while the cover follows
                        let span = window.upperBound - window.lowerBound
                        var pan = 0.0
                        if px > w, px > previousX { pan = Double((px - max(previousX, w)) / w) * span }
                        if px < 0, px < previousX { pan = Double((px - min(previousX, 0)) / w) * span }
                        pan = min(max(pan, -window.lowerBound), total - window.upperBound)
                        let moved = (window.lowerBound + pan)...(window.upperBound + pan)
                        let t = min(max(moved.lowerBound, moved.lowerBound + Double(px / w) * span), moved.upperBound)
                        project.moveCover(to: ((t * fps).rounded(.down) + 0.5) / fps, keeping: spanAtBegin)
                        if pan != 0, moved.contains(project.rangeEnd) { fine = moved }
                    } else {
                        project.moveCover(to: time(px), keeping: spanAtBegin)
                    }
                    if fromLock {
                        project.scrub(at: project.rangeEnd)                 // stays on the lock screen
                    } else {
                        project.seek(to: project.rangeEnd)
                    }
                }
                .onEnded { _ in end("调整封面") })
            .onAppear { coverRowWidth = w }
            .onChange(of: w) { coverRowWidth = w }
            .help("点按或拖动，动画停在哪一帧（O）；拖动时按住不动片刻，时间轴放大，可以逐帧微调")
            .accessibilityElement()
            .accessibilityLabel("封面")
            .accessibilityValue(clock(project.rangeEnd))
            .accessibilityAdjustableAction { nudge(start: false, $0) }
        }
    }

    /// A thin mark for every source frame on the zoomed cover row.
    private func frameTicks(shown: ClosedRange<Double>, width: CGFloat) -> some View {
        let fps = max(1, project.source?.frameRate ?? 30)
        return Canvas { gc, size in
            let span = shown.upperBound - shown.lowerBound
            var f = (shown.lowerBound * fps).rounded(.up)
            while f / fps <= shown.upperBound {
                let px = CGFloat((f / fps - shown.lowerBound) / span) * size.width
                gc.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: 5)), with: .color(.white.opacity(0.6)))
                f += 1
            }
        }
        .frame(width: width, height: coverHeight)
        .transition(.opacity)
    }

    // MARK: row 2, the start

    /// The seconds before the cover the start row shows: enough to see where it turns jumpy, and the chosen start with
    /// room to drag further (the window grows again after each drag).
    private var zoomWindow: ClosedRange<Double> {
        let cover = project.rangeEnd
        if let held = coverDragWidth {
            let lo = max(0, cover - held)
            return lo...max(cover, lo + 0.001)
        }
        let lo = max(0, cover - zoomWidth)
        return lo...max(cover, lo + 0.001)
    }

    /// How many seconds the start row wants to show, before it is cut at 0:00.
    private var zoomWidth: Double {
        let cover = project.rangeEnd
        let reach = project.jumpyStart.map { cover - $0 } ?? project.smoothStart.map { 2 * (cover - $0) } ?? 0
        return max(reach * 1.4, project.span * 1.25, 2)
    }

    private var startRow: some View {
        GeometryReader { geo in
            let shown = frozenWindow ?? zoomWindow
            let span = shown.upperBound - shown.lowerBound
            let inner = max(1, geo.size.width - handleWidth - 3)        // room for the handle left, the frame right
            let x = { (t: Double) -> CGFloat in handleWidth + CGFloat((t - shown.lowerBound) / span) * inner }
            let time = { (px: CGFloat) -> Double in shown.lowerBound + Double(min(max(0, (px - handleWidth) / inner), 1)) * span }
            let startX = x(project.rangeStart), endX = x(project.rangeEnd)
            let top = tickArea

            ZStack(alignment: .topLeading) {
                ticks(x: x)

                // pictures of this window once decoded; until then a placeholder that says so. (Stretching the
                // whole-video strip to the window made each of its pictures hundreds of points wide, 11-18:
                // 「在加载的时候会变得很大一张」)
                ZStack(alignment: .topLeading) {
                    if let zoom = zoomStrip, zoom.window == shown {
                        filmstrip(zoom.images, width: inner, height: startHeight).transition(.opacity)
                    } else {
                        LoadingStrip(slots: 16).frame(width: inner, height: startHeight).transition(.opacity)
                    }
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, startX - handleWidth), height: startHeight)
                }
                .frame(width: inner, height: startHeight, alignment: .topLeading)
                .clipped()
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(x: handleWidth, y: top)
                .contentShape(Rectangle())
                .gesture(startDrag(time: time, shown: shown))

                // the chosen stretch, and its handle
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 7, topTrailingRadius: 7)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(3, endX - startX + 3), height: startHeight)
                    .offset(x: startX, y: top)
                    .allowsHitTesting(false)
                handle.offset(x: startX - handleWidth, y: top)
                    .gesture(startDrag(time: time, shown: shown))
                    .help("起点：从这里到封面整段都会播，离封面越近越平滑（I）")
                    .accessibilityElement()
                    .accessibilityLabel("起点")
                    .accessibilityValue(clock(project.rangeStart))
                    .accessibilityAdjustableAction { nudge(start: true, $0) }
                playhead(at: x(project.playhead), height: startHeight).offset(y: top)
                    .opacity(shown.contains(project.playhead) ? 1 : 0)

                zoneBar(shown: shown, x: x)
                    .frame(width: inner, height: zoneHeight)
                    .offset(x: handleWidth, y: top + startHeight + zoneGap)

                if let i = hoverTick, dragging == nil { tickBubble(i, x: x, width: geo.size.width) }
                if let f = hoverZone, dragging == nil {
                    zoneBubble(at: shown.lowerBound + f * span, x: handleWidth + CGFloat(f) * inner, top: top)
                }
            }
            .coordinateSpace(name: "start")
        }
        .task(id: zoomWindow) {
            // pictures for the window, after the range has stopped moving
            guard let asset = project.previewAsset else { return }
            let target = zoomWindow
            if zoomStrip?.window == target { return }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let images = await PreviewImages.filmstrip(of: asset, from: target.lowerBound, to: target.upperBound, count: 16)
            if !Task.isCancelled, !images.isEmpty { withAnimation(.easeOut(duration: 0.2)) { zoomStrip = (target, images) } }
        }
    }

    private func startDrag(time: @escaping (CGFloat) -> Double, shown: ClosedRange<Double>) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("start"))
            .onChanged { g in
                if dragging == nil {
                    begin(.start)
                    frozenWindow = shown
                    project.startIsAuto = false
                }
                project.rangeStart = max(0, min(time(g.location.x), project.rangeEnd - project.minSpan))
                if fromLock {
                    project.scrub(at: project.rangeStart)                   // the start's picture while it is dragged
                } else {
                    project.seek(to: project.rangeStart)
                }
            }
            .onEnded { _ in end("调整起点") }
    }

    /// The 11 planned frames above the start row; the cover is the tall yellow one. Pointing at one shows its picture,
    /// clicking opens the details at that frame. Shown only while the pointer is on the bar.
    private func ticks(x: @escaping (Double) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(project.times.enumerated()), id: \.offset) { i, t in
                let isCover = i == project.times.count - 1
                let lit = hoverTick == i
                Capsule().fill(isCover ? Color.yellow : Color.white.opacity(lit ? 1 : 0.8))
                    .frame(width: lit ? 3 : 2, height: isCover || lit ? 11 : 7)
                    .offset(x: x(t) - (lit ? 1.5 : 1), y: tickArea - 2 - (isCover || lit ? 11 : 7))
            }
            // the planned frames belong to the old cover while it is dragged: hidden until the new plan
            .opacity(coverIsMoving ? 0 : barHovered || hoverTick != nil || dragging != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: barHovered)
            .allowsHitTesting(false)
            Color.clear
                .frame(maxWidth: .infinity).frame(height: tickArea)
                .allowsHitTesting(!coverIsMoving)              // the marks of another cover's plan: nothing to point at
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named("start")) { phase in
                    guard !SnapshotHook.scripted else { return }
                    if case .active(let p) = phase { hoverTick = nearestTick(to: p.x, x: x) } else { hoverTick = nil }
                }
                .gesture(SpatialTapGesture(coordinateSpace: .named("start")).onEnded { tap in
                    if let i = nearestTick(to: tap.location.x, x: x) {
                        withAnimation(.easeOut(duration: 0.25)) { project.showFrameDetails(i) }
                    }
                })
                .accessibilityElement()
                .accessibilityLabel("动画的 \(project.times.count) 帧")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { project.showFrameDetails(project.times.count - 1) }
        }
    }

    // MARK: the colour bar

    private enum Zone { case smooth, jumpy, flashy, unknown }

    /// How the animation feels for a start at `t`: the same thresholds as the sidebar (SegmentPlanner.Feel).
    private func zone(at t: Double) -> Zone {
        guard !coverIsMoving, t <= project.rangeEnd, let smooth = project.smoothStart else { return .unknown }
        if t >= smooth - 0.005 { return .smooth }
        guard let jumpy = project.jumpyStart else { return .unknown }
        return t >= jumpy - 0.005 ? .jumpy : .flashy
    }

    private func color(_ zone: Zone) -> Color {
        switch zone {
        case .smooth: .green
        case .jumpy: .orange
        case .flashy: .red
        case .unknown: .white.opacity(0.2)
        }
    }

    private func words(_ zone: Zone) -> String {
        switch zone {
        case .smooth: "平滑"
        case .jumpy: "略有跳动"
        case .flashy: "跳动明显"
        case .unknown: "还在计算"
        }
    }

    private func zoneBar(shown: ClosedRange<Double>, x: @escaping (Double) -> CGFloat) -> some View {
        let lo = shown.lowerBound, hi = shown.upperBound
        // measured for the old cover while the cover is dragged: grey (还在计算) until the new plan, not misplaced
        let jumpyStart = coverIsMoving ? nil : project.jumpyStart
        let smoothStart = coverIsMoving ? nil : project.smoothStart
        let jumpy = min(max(jumpyStart ?? lo, lo), hi), smooth = min(max(smoothStart ?? hi, lo), hi)
        let origin = x(lo), width = x(hi) - x(lo)
        let bands: [(from: Double, to: Double, zone: Zone)] = [
            (lo, jumpy, jumpyStart == nil ? .unknown : .flashy),
            (jumpy, smooth, jumpyStart == nil ? .unknown : .jumpy),
            (smooth, hi, smoothStart == nil ? .unknown : .smooth),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, b in
                Rectangle().fill(color(b.zone))
                    .frame(width: max(0, x(b.to) - x(b.from)), height: zoneHeight)
                    .offset(x: x(b.from) - origin)
            }
        }
        .frame(width: width, height: zoneHeight, alignment: .topLeading)
        .clipShape(Capsule())
        // the bar itself, plus a few points above and below like a slider's track: 6 pt alone is hard to point at
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard !SnapshotHook.scripted else { return }
            if case .active(let p) = phase, width > 0 {
                hoverZone = min(max(0, Double(p.x / width)), 1)
            } else {
                hoverZone = nil
            }
        }
        .padding(.vertical, -5)
        .accessibilityHidden(true)
    }

    /// The words for the colour under the pointer, just above it.
    private func zoneBubble(at t: Double, x: CGFloat, top: CGFloat) -> some View {
        let z = zone(at: t)
        return HStack(spacing: 5) {
            Circle().fill(color(z)).frame(width: 7, height: 7)
            Text(words(z)).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassPanel(cornerRadius: 9)
        .fixedSize()
        // centred on the pointer; `position` keeps it from widening the row (an alignment guide pushed the row right)
        .position(x: x, y: top + startHeight + zoneGap - 13)          // just above the bar, at the pointer
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: pieces

    private func filmstrip(_ images: [CGImage], width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(1, images.count)), height: height).clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    private func playhead(at px: CGFloat, height: CGFloat) -> some View {
        Capsule().fill(.white).frame(width: 2, height: height + 6)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .offset(x: px - 1, y: -3)
            .opacity(project.viewMode == .source ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var handle: some View {
        UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7, bottomTrailingRadius: 0, topTrailingRadius: 0)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: startHeight)
            .overlay(Image(systemName: "chevron.compact.left")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            .contentShape(Rectangle().inset(by: -6))
            .resizeCursor()
    }

    @ViewBuilder
    private func tickBubble(_ i: Int, x: (Double) -> CGFloat, width: CGFloat) -> some View {
        if i < project.times.count, i < project.frames.count {
            let isCover = i == project.times.count - 1
            let h: CGFloat = 96
            let w = h * CGFloat(project.aspect)
            VStack(spacing: 6) {
                Image(decorative: project.frames[i], scale: 1).resizable()
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCover ? Color.yellow : .white.opacity(0.15), lineWidth: isCover ? 2 : 1))
                Text((isCover ? "封面" : "第 \(i + 1) 帧") + " · " + clock(project.times[i]))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            .padding(8)
            .glassPanel(cornerRadius: 12)
            .fixedSize()
            .modifier(Above(x: x(project.times[i]), boxWidth: w + 16, width: width))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The planned frame whose mark is nearest to `px`, if the pointer is near the marks at all.
    private func nearestTick(to px: CGFloat, x: (Double) -> CGFloat) -> Int? {
        guard let (i, d) = project.times.enumerated().map({ ($0.offset, abs(x($0.element) - px)) }).min(by: { $0.1 < $1.1 }),
              d < 24 else { return nil }
        return i
    }

    // MARK: dragging

    /// Neither drag switches views (11-12: dragging the cover in the lock-screen view jumped to the video and back):
    /// in the lock-screen view the picked cover shows on the lock screen, in the video view the video follows.
    private func begin(_ what: Drag) {
        dragging = what
        coverAtBegin = project.rangeEnd
        spanAtBegin = project.span
        // held from the first cover drag until that cover's plan answers; a second drag meanwhile keeps it
        if what == .cover, coverDragWidth == nil { coverDragWidth = zoomWidth }
        fromLock = project.viewMode == .lockScreen
        project.pause()
        project.beginEdit()
    }

    /// Restarts the wait for a hold; once the pointer has rested long enough, fine scrubbing starts where it is.
    private func holdStill(at px: CGFloat) {
        holdTimer?.cancel()
        holdX = px
        holdTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, dragging == .cover, fine == nil else { return }
            // the seconds around the cover, `pointsPerFrame` per frame, placed so the cover stays under the pointer
            let total = max(project.duration, 0.001), w = max(1, coverRowWidth)
            let fps = max(1, project.source?.frameRate ?? 30)
            let span = min(total, Double(w / pointsPerFrame) / fps)
            let lo = min(max(0, project.rangeEnd - Double(min(max(0, lastX / w), 1)) * span), total - span)
            let window = lo...(lo + span)
            withAnimation(.spring(duration: 0.35)) { fine = window }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func end(_ undoName: String) {
        holdTimer?.cancel()
        holdTimer = nil
        withAnimation(.spring(duration: 0.35)) { fine = nil }
        fineStrip = nil
        // the cover's picture stays until the new plan shows it; the start's goes, back to the cover
        if fromLock { project.endScrub(keepPicture: dragging == .cover && project.rangeEnd != coverAtBegin) }
        project.endEdit(undoName)
        dragging = nil
        withAnimation(.easeOut(duration: 0.25)) { frozenWindow = nil }
        // a moved cover keeps the start row's width until its own plan has answered (`onChange(of: coverIsMoving)`):
        // in between, the old cover's starts made the row jump wider and back (11-18 「松开光标之后会向左边跳一下」)
    }

    /// VoiceOver: one source frame per step.
    private func nudge(start: Bool, _ direction: AccessibilityAdjustmentDirection) {
        let d = (direction == .increment ? 1.0 : -1.0) / max(1, project.source?.frameRate ?? 30)
        project.beginEdit()
        if start {
            project.startIsAuto = false
            project.rangeStart = min(max(0, project.rangeStart + d), project.rangeEnd - project.minSpan)
        } else {
            project.moveCover(to: project.rangeEnd + d)
        }
        project.endEdit(start ? "调整起点" : "调整封面")
    }

    private func clock(_ t: Double, precise: Bool = false) -> String {
        precise ? String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                : String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// Empty picture slots with a light sweeping across them, while a strip's pictures are decoded.
private struct LoadingStrip: View {
    let slots: Int
    @State private var phase: CGFloat = -0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(0..<slots, id: \.self) { _ in Rectangle().fill(.white.opacity(0.07)) }
            }
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.3)
                    .offset(x: phase * g.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(reduceMotion ? 0 : 1)
            }
            .clipped()
            .overlay { ProgressView().controlSize(.small) }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityLabel("正在载入画面")
    }
}

/// Places a bubble above the start row, centred on `x` but kept inside the bar.
private struct Above: ViewModifier {
    let x: CGFloat
    let boxWidth: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .alignmentGuide(.bottom) { $0[.bottom] }
            .frame(width: width, alignment: .leading)
            .offset(x: min(max(0, x - boxWidth / 2), max(0, width - boxWidth)))
            .frame(height: 0, alignment: .bottom)
            .offset(y: -10)
    }
}
