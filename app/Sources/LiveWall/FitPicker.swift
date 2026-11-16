import LiveWallCore
import SwiftUI

/// 完整 / 铺满 as two small pictures of what each does to this video on this screen, instead of two words.
struct FitPicker: View {
    @Bindable var project: Project

    var body: some View {
        HStack(spacing: 10) {
            tile(.squeeze, title: "完整", caption: squeezeCaption)
            tile(.crop, title: "铺满", caption: sourceAspect > project.aspect ? "裁掉左右两边" : "裁掉上下两边")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画面")
    }

    private var squeezeCaption: String {
        let d = project.squeezeDistortion
        if d.amount < 0.03 { return "保留全部画面" }
        return "画面会被\(d.horizontal ? "挤窄" : "压扁") \(Int((d.amount * 100).rounded()))%"
    }

    /// The source picture at the cover, as it is (not reframed).
    private var still: CGImage? {
        let strip = project.filmstrip
        guard !strip.isEmpty, project.duration > 0 else { return nil }
        let i = Int((project.rangeEnd / project.duration * Double(strip.count - 1)).rounded())
        return strip[min(max(0, i), strip.count - 1)]
    }

    /// The picture says what each does; the words stay in the tooltip and for VoiceOver.
    private func tile(_ mode: ReframeMode, title: String, caption: String) -> some View {
        let selected = project.mode == mode
        return Button {
            project.mode = mode
        } label: {
            // like the Appearance choices in System Settings: no card, the selection is a ring around the picture
            VStack(spacing: 6) {
                FitDemo(mode: mode, image: still, sourceAspect: sourceAspect, screenAspect: project.aspect,
                        focus: CGPoint(x: project.focusX, y: project.focusY), selected: selected)
                    .frame(height: 72)
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .crop ? "铺满：\(caption)。切到「视频」可以拖动取景框" : "完整：\(caption)")
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sourceAspect: Double {
        guard let s = project.source?.size, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }
}

/// One tile's picture: a screen outline and the result in it. Pointing at it (or choosing it) plays once how it gets
/// there, from the other choice's picture: 完整 starts from the filled picture spilling past the screen and squeezes
/// it in; 铺满 starts from the whole picture inside the screen (bars around it) and enlarges it until it fills.
private struct FitDemo: View {
    let mode: ReframeMode
    let image: CGImage?
    let sourceAspect: Double
    let screenAspect: Double
    /// Where the crop sits (0...1 each way), as in the real crop.
    let focus: CGPoint
    let selected: Bool

    /// false: the starting picture; true: the result.
    @State private var applied = true
    @State private var run: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let box = geo.size
            // the screen smaller than the tile, so what a crop cuts off shows around it
            let screen = fit(aspect: screenAspect, in: CGSize(width: box.width * 0.74, height: box.height * 0.8))
            let filled = fill(aspect: sourceAspect, around: screen)
            let filledShift = CGSize(width: (0.5 - focus.x) * (filled.width - screen.width),
                                     height: (0.5 - focus.y) * (filled.height - screen.height))
            let start: (size: CGSize, shift: CGSize) = mode == .squeeze ? (filled, filledShift) : (fit(aspect: sourceAspect, in: screen), .zero)
            let end: (size: CGSize, shift: CGSize) = mode == .squeeze ? (screen, .zero) : (filled, filledShift)
            let now = applied ? end : start
            let corner = min(screen.width, screen.height) * 0.12
            let picture = { (opacity: Double) in
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable()
                            .frame(width: now.size.width, height: now.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                            // a thin edge on the part outside the screen, so its extent reads
                            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .strokeBorder(.white.opacity(opacity < 1 ? 0.35 : 0), lineWidth: 0.5))
                            .opacity(opacity)
                            .offset(now.shift)
                    }
                }
            }
            ZStack {
                // whatever spills past the screen, faint
                picture(0.45)
                ZStack {
                    Color.black
                    picture(1)
                }
                .frame(width: screen.width, height: screen.height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                // the screen's edge; when chosen, the ring outside it takes over
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0 : 0.5), lineWidth: 1)
                    .frame(width: screen.width, height: screen.height)
                // the selection ring, a little outside the screen
                RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .frame(width: screen.width + 8, height: screen.height + 8)
                    .opacity(selected ? 1 : 0)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
        }
        .onHover { inside in
            guard !SnapshotHook.scripted else { return }
            if inside { play() }
        }
        .onChange(of: selected) { _, now in if now { play() } }
        .onDisappear { run?.cancel() }
        .accessibilityHidden(true)
    }

    /// Hold the starting picture for a moment, then move to the result once.
    private func play() {
        guard !reduceMotion else { return }
        run?.cancel()
        applied = false
        run = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { applied = true }
        }
    }

    private func fit(aspect: Double, in box: CGSize) -> CGSize {
        let a = CGFloat(aspect)
        return box.width / box.height > a ? CGSize(width: box.height * a, height: box.height)
                                          : CGSize(width: box.width, height: box.width / a)
    }

    private func fill(aspect: Double, around box: CGSize) -> CGSize {
        let a = CGFloat(aspect)
        return box.width / box.height > a ? CGSize(width: box.width, height: box.width / a)
                                          : CGSize(width: box.height * a, height: box.height)
    }
}
