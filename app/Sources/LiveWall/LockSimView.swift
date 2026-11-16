import CoreGraphics
import SharedUI
import SwiftUI

/// Imitates how the lock screen plays the 10 frames before the cover (docs/research-notes.md 一.2): forward once from
/// the first frame in about 0.75 s, fast first and slowing down, with neighbouring frames blended, then it rests on
/// the cover. Colours are NOT simulated — only the motion. Click to play it again, like waking the phone.
///
/// Before it, the screen goes from the cover to the first frame in ~0.35 s, drawn as a fade: the timecode test showed
/// numbers only counting up, so a frame-by-frame rewind is not what people see (an earlier version drew one, and moving
/// content looked like it went back and forth).
struct LockSimView: View {
    let frames: [CGImage]
    let aspect: Double
    /// Changing it plays the animation again.
    var replayToken = 0
    /// Rest on the cover and do not replay while the cover is being scrubbed (each scrubbed picture is a new frame).
    var holdOnCover = false
    @State private var startDate = Date()
    /// Only while the animation plays: a resting preview must not redraw every frame (energy use while idle).
    @State private var running = true
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let back = LockScreen.returnSeconds
    private let forward = LockScreen.playSeconds

    var body: some View {
        GeometryReader { geo in
            let short = min(geo.size.width, geo.size.height)
            let bezel = max(4, short * 0.022)
            let corner = short * 0.075
            TimelineView(.animation(minimumInterval: nil, paused: !running)) { context in
                let position = holdOnCover ? Double(max(0, frames.count - 1)) : framePosition(at: context.date.timeIntervalSince(startDate))
                Canvas { gc, size in
                    draw(position: position, in: &gc, size: size)
                }
                .overlay(alignment: .top) { clock(short: short) }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .padding(bezel)
            .background(RoundedRectangle(cornerRadius: corner + bezel, style: .continuous).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: corner + bezel, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: short * 0.05, y: short * 0.02)
            .overlay(alignment: .bottom) {
                Label("点按重播", systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .glassCapsule()
                    .padding(.bottom, bezel + short * 0.05)
                    .opacity(hovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: hovering)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { replay() }
            .onHover { hovering = $0 && !SnapshotHook.scripted }
            .accessibilityElement()
            .accessibilityLabel("锁屏预览")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("播放锁屏动画")
            .accessibilityAction { replay() }
        }
        .aspectRatio(aspect, contentMode: .fit)
        // new plan: play it once (with Reduce Motion, only when asked)
        .onChange(of: frames.map(ObjectIdentifier.init)) { _, _ in if !reduceMotion, !holdOnCover { replay() } }
        .onChange(of: replayToken) { _, _ in replay() }
        .task(id: startDate) {
            running = true
            try? await Task.sleep(for: .seconds(back + forward + 0.1))
            if !Task.isCancelled { running = false }
        }
    }

    private func replay() { startDate = Date() }

    private func clock(short: CGFloat) -> some View {
        VStack(spacing: -short * 0.01) {
            // today's date, as the lock screen shows it; the time stays 9:41, Apple's convention for screenshots
            Text(Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))).font(.system(size: short * 0.045, weight: .semibold))
            Text("9:41").font(.system(size: short * 0.2, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.95))
        .shadow(color: .black.opacity(0.2), radius: 6)
        .padding(.top, short * 0.07)
        .allowsHitTesting(false)
    }

    /// -1 ... frames.count - 1, fractional; -1 ... 0 is the fade from the cover to the first frame.
    private func framePosition(at t: Double) -> Double {
        let last = Double(max(0, frames.count - 1))
        if t < back { return max(0, t) / back - 1 }
        if t < back + forward {
            let u = (t - back) / forward
            return last * (1 - (1 - u) * (1 - u))                       // ease out: fast first, then slow
        }
        return last
    }

    private func draw(position: Double, in gc: inout GraphicsContext, size: CGSize) {
        guard !frames.isEmpty else { return }
        let rect0 = CGRect(origin: .zero, size: size)
        if position < 0 {
            gc.draw(Image(decorative: frames[frames.count - 1], scale: 1), in: rect0)
            gc.opacity = position + 1
            gc.draw(Image(decorative: frames[0], scale: 1), in: rect0)
            return
        }
        let lower = min(frames.count - 1, max(0, Int(position.rounded(.down))))
        let upper = min(frames.count - 1, lower + 1)
        let mix = position - Double(lower)
        let rect = CGRect(origin: .zero, size: size)
        gc.draw(Image(decorative: frames[lower], scale: 1), in: rect)
        if upper != lower, mix > 0.001 {
            gc.opacity = mix
            gc.draw(Image(decorative: frames[upper], scale: 1), in: rect)
        }
    }
}
