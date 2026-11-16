import SharedUI
import SwiftUI

/// The timeline in two rows, in the order people decide (11-12, the user picked this from three mock-ups in
/// `_handoff/1111-时间轴三版.html`):
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
    /// The start row's window, held still while the start is dragged: the scale must not change under the pointer.
    @State private var frozenWindow: ClosedRange<Double>?
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
    }

    private func title(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(text).fontWeight(.semibold)
            Spacer()
            trailing().foregroundStyle(.secondary)
        }
        .font(.caption)
        .opacity(dragging != nil || project.isPlaying ? 0.5 : 1)
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
            Text("封面 " + clock(project.rangeEnd)).monospacedDigit()
        }
        .help("动画停在这一帧，也是锁屏平时的画面")
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
            let x = { (t: Double) -> CGFloat in CGFloat(t / total) * w }
            let time = { (px: CGFloat) -> Double in Double(min(max(0, px / w), 1)) * total }
            let startX = x(project.rangeStart), endX = x(project.rangeEnd)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    filmstrip(project.filmstrip, width: w, height: coverHeight)
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
                    project.moveCover(to: time(g.location.x))
                    if fromLock {
                        project.scrubCover(at: project.rangeEnd)            // stays on the lock screen
                    } else {
                        project.seek(to: project.rangeEnd)
                    }
                }
                .onEnded { _ in end("调整封面") })
            .help("点按或拖动，动画停在哪一帧（O）")
            .accessibilityElement()
            .accessibilityLabel("封面")
            .accessibilityValue(clock(project.rangeEnd))
            .accessibilityAdjustableAction { nudge(start: false, $0) }
        }
    }

    // MARK: row 2, the start

    /// The seconds before the cover the start row shows: enough to see where it turns jumpy, and the chosen start with
    /// room to drag further (the window grows again after each drag).
    private var zoomWindow: ClosedRange<Double> {
        let cover = project.rangeEnd
        let reach = project.jumpyStart.map { cover - $0 } ?? project.smoothStart.map { 2 * (cover - $0) } ?? 0
        let width = max(reach * 1.4, project.span * 1.25, 2)
        let lo = max(0, cover - width)
        return lo...max(cover, lo + 0.001)
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

                // pictures: the whole-video strip scaled to the window, finer ones on top once ready
                ZStack(alignment: .topLeading) {
                    let full = inner * CGFloat(max(project.duration, 0.001) / span)
                    filmstrip(project.filmstrip, width: full, height: startHeight)
                        .offset(x: -CGFloat(shown.lowerBound / span) * inner)
                        .frame(width: inner, height: startHeight, alignment: .leading)
                    if let zoom = zoomStrip, zoom.window == shown {
                        filmstrip(zoom.images, width: inner, height: startHeight).transition(.opacity)
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
            guard let asset = project.source?.asset else { return }
            let target = zoomWindow
            if zoomStrip?.window == target { return }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let images = await Project.filmstrip(of: asset, from: target.lowerBound, to: target.upperBound, count: 16)
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
                if !fromLock { project.seek(to: project.rangeStart) }
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
            .opacity(barHovered || hoverTick != nil || dragging != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: barHovered)
            .allowsHitTesting(false)
            Color.clear
                .frame(maxWidth: .infinity).frame(height: tickArea)
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
        guard t <= project.rangeEnd, let smooth = project.smoothStart else { return .unknown }
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
        let jumpy = min(max(project.jumpyStart ?? lo, lo), hi), smooth = min(max(project.smoothStart ?? hi, lo), hi)
        let origin = x(lo), width = x(hi) - x(lo)
        let bands: [(from: Double, to: Double, zone: Zone)] = [
            (lo, jumpy, project.jumpyStart == nil ? .unknown : .flashy),
            (jumpy, smooth, project.jumpyStart == nil ? .unknown : .jumpy),
            (smooth, hi, project.smoothStart == nil ? .unknown : .smooth),
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
        fromLock = project.viewMode == .lockScreen
        project.pause()
        project.beginEdit()
    }

    private func end(_ undoName: String) {
        project.endEdit(undoName)
        if dragging == .cover { project.endScrub(coverMoved: project.rangeEnd != coverAtBegin) }
        dragging = nil
        withAnimation(.easeOut(duration: 0.25)) { frozenWindow = nil }        // rescale to the new range
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

    private func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
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
