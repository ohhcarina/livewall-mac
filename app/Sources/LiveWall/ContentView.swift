import AVKit
import LiveWallCore
import SharedUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var project = Project()
    @State private var dropTargeted = false
    @State private var confirmJumpyExport = false
    @State private var finished: FinishedExport?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if project.source == nil {
                EmptyState(project: project, targeted: dropTargeted)
            } else {
                // a plain split instead of `.inspector`: the toolbar then spans the whole window and its trailing items
                // line up with the sidebar's edge
                HStack(spacing: 0) {
                    Editor(project: project)
                    Divider().ignoresSafeArea()
                    Sidebar(project: project)
                        .frame(width: 320)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        // a media editor: one dark, immersive window, like Photos' editing view or Final Cut
        .preferredColorScheme(.dark)
        .navigationTitle(project.sourceURL?.deletingPathExtension().lastPathComponent ?? "LiveWall")
        .navigationSubtitle(subtitle)
        .modifier(DocumentProxy(url: project.sourceURL))
        .toolbar { toolbar }
        .focusedSceneValue(\.project, project)
        .onAppear { project.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in project.undoManager = new }
        .task {
            // `LiveWall <video>` (and Finder's Open With) start with the file already loaded
            if let path = CommandLine.arguments.dropFirst().first(where: { FileManager.default.fileExists(atPath: $0) }) {
                project.open(URL(fileURLWithPath: path))
            }
            await SnapshotHook.run(project: project)
        }
        .onOpenURL { url in if url.isFileURL { project.open(url) } }     // Finder's Open With, Dock drops
        .onReceive(NotificationCenter.default.publisher(for: .openVideo)) { _ in
            if !project.isExporting { pickVideo(project) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportWallpaper)) { _ in requestExport() }
        .onChange(of: project.exportCount) { _, _ in
            if let result = project.lastExport { finished = FinishedExport(result: result) }
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first(where: isMovie) else { return false }
            project.open(url)
            return true
        }, isTargeted: { dropTargeted = $0 })
        .overlay {
            if project.source != nil { DropHighlight(targeted: dropTargeted) }
        }
        .confirmationDialog(project.verdict?.title ?? "", isPresented: $confirmJumpyExport) {
            Button("仍然导出") { startExport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(project.verdict?.advice ?? "")
        }
        .sheet(item: $finished) { done in ExportDoneSheet(project: project, result: done.result) }
        .alert("无法完成操作", isPresented: Binding(get: { if case .failed = project.phase { true } else { false } },
                                             set: { if !$0 { project.phase = project.source == nil ? .empty : .ready } })) {
            Button("好") {}
        } message: {
            if case .failed(let m) = project.phase { Text(m) }
        }
    }

    private var subtitle: String {
        guard let source = project.source else { return "" }
        return String(format: "%.0f × %.0f · %.1f 秒", source.size.width, source.size.height, project.duration)
    }

    private func requestExport() {
        guard project.canExport else { return }
        if project.verdict?.level == .bad { confirmJumpyExport = true } else { startExport() }
    }

    /// Renders first, into a temporary folder; where the wallpaper goes is chosen on the finished sheet.
    private func startExport() {
        project.pause()
        project.exportToTemporaryFolder()
    }

    // the same toolbar with or without a video, so the window chrome does not jump when one is opened
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // starting over with another video: a + beside export, like Shortcuts or Freeform; the menu item carries the
        // words. The fixed spacer puts each on its own piece of glass.
        ToolbarItem(placement: .primaryAction) { newButton }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) { exportButton }
    }

    private var newButton: some View {
        Button { pickVideo(project) } label: { Label("新建", systemImage: "plus") }
            .labelStyle(.iconOnly)
            .disabled(project.isExporting)
            .help("用另一段视频新建（⌘N）")
    }

    private var exportButton: some View {
        Button { requestExport() } label: {
            if let step = project.exportStep {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step)
                }
            } else {
                Label("导出壁纸", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
        }
        .glassButtonStyle(prominent: true)
        .disabled(!project.canExport && !project.isExporting)
        .allowsHitTesting(!project.isExporting)
        .help("导出为锁屏壁纸（⌘E）")
    }
}

/// Only files that are video (by their type, not their name), so a dropped PDF or link is refused at the door.
private func isMovie(_ url: URL) -> Bool {
    guard url.isFileURL, let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
    return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
}

/// The dashed outline that says "drop it here", over the empty screen or the editor.
private struct DropHighlight: View {
    let targeted: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.accentColor.opacity(0.06)))
            .padding(16)
            .opacity(targeted ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: targeted)
            .allowsHitTesting(false)
    }
}

private struct FinishedExport: Identifiable {
    let id = UUID()
    let result: BuildResult
}

/// The source file as the window's document: proxy icon in the title, ⌘-click for its folder.
private struct DocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

@MainActor
private func pickVideo(_ project: Project) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    present(panel) { if $0 == .OK, let url = panel.url { project.open(url) } }
}

/// "存储到…": copies the finished package where the person chooses; `report` gets the reason when that fails.
@MainActor
private func saveWallpaperPanel(_ project: Project, report: @escaping (String) -> Void) {
    guard let result = project.lastExport else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = result.packageURL.lastPathComponent
    panel.allowedContentTypes = [UTType(filenameExtension: "pvt") ?? .data]
    panel.canCreateDirectories = true
    // otherwise leave it to the system, which reopens the last folder this app saved to
    if let saved = project.savedCopy { panel.directoryURL = saved.deletingLastPathComponent() }
    present(panel) { response in
        guard response == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "pvt" { url.deletePathExtension(); url.appendPathExtension("pvt") }
        if let why = project.saveCopy(to: url) { report(why) }
    }
}

/// Open and save panels as sheets on the window, like other Mac apps, not app-modal dialogs.
/// On the main window, never the key one: right after 仍然导出 the key window is the confirmation dialog, which is
/// closing, and it took the save panel down with it.
@MainActor
private func present(_ panel: NSSavePanel, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
    // from the finished-export sheet the panel hangs off that sheet; otherwise off the main window
    let sheet = NSApp.keyWindow.flatMap { $0.sheetParent != nil ? $0 : nil }
    if let window = sheet ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
        panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
        handler(panel.runModal())
    }
}

// MARK: - empty

private struct EmptyState: View {
    let project: Project
    let targeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 28) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                    .scaleEffect(targeted && !reduceMotion ? 1.08 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: targeted)
                    .accessibilityHidden(true)
                Text("把视频做成实况锁屏壁纸").font(.largeTitle.bold())

                Button { pickVideo(project) } label: {
                    Label("选择视频…", systemImage: "film.stack").font(.title3.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.extraLarge)
                Text("或者直接把视频拖进来").font(.callout).foregroundStyle(.tertiary)
                if let p = project.proxyProgress {
                    // the editing copy: a few seconds for 4K, once per video
                    VStack(spacing: 6) {
                        ProgressView(value: p).frame(width: 220)
                        Text("正在准备编辑用的副本…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if project.phase == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(40)
            DropHighlight(targeted: targeted)
        }
    }
}

// MARK: - canvas

/// The editing canvas: the picture is what matters.
private struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

private struct Editor: View {
    @Bindable var project: Project
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Clicking the switch cross-fades the canvas; switches caused by dragging (to show the frame being picked) are instant.
    private var viewMode: Binding<Project.ViewMode> {
        Binding(get: { project.viewMode },
                set: { v in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { project.viewMode = v } })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop()
            // stacked, not overlaid: the bar's height changes with its rows (two since 11-12)
            VStack(spacing: 16) {
                stage
                    .overlay {
                        // another video's editing copy is being made while this one is still shown (11-18 review)
                        if let p = project.proxyProgress {
                            VStack(spacing: 8) {
                                ProgressView(value: p).frame(width: 220)
                                Text("正在准备编辑用的副本…").font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(16)
                            .glassPanel(cornerRadius: 16)
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 60)
                TrimBar(project: project)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .disabled(project.isExporting)
            }
        }
        .overlay(alignment: .top) { header }
        // keyboard, only while the canvas has focus (a text field in the sidebar keeps its keys)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onTapGesture { focused = true }
        .onChange(of: project.rangeStart) { _, _ in focused = true }
        .onChange(of: project.rangeEnd) { _, _ in focused = true }
        .onChange(of: project.viewMode) { _, _ in focused = true }
        .onKeyPress(.space) {
            if project.viewMode == .lockScreen { project.wake() } else { project.togglePlay() }
            return .handled
        }
        .onKeyPress(.leftArrow) { project.viewMode = .source; project.step(frames: -1); return .handled }
        .onKeyPress(.rightArrow) { project.viewMode = .source; project.step(frames: 1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            if press.characters.lowercased() == "i" { project.setStartToPlayhead() } else { project.setEndToPlayhead() }
            return .handled
        }
    }

    /// What the canvas shows, centred over the picture (like the mode switch in Photos' editor), and any blocking problem.
    private var header: some View {
        VStack(spacing: 10) {
            ViewModeSwitch(selection: viewMode)
                .help("在锁屏预览和原始视频之间切换（⌘1、⌘2）")
            if let reason = project.blockedReason {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassPanel(cornerRadius: 14)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 30)
    }

    @ViewBuilder private var stage: some View {
        switch project.viewMode {
        case .lockScreen:
            if project.frames.isEmpty {
                VStack(spacing: 12) {
                    if let why = project.planFailed {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                        Text(why).foregroundStyle(.secondary)
                        Button("重试", systemImage: "arrow.clockwise") { project.replan(immediately: true) }
                    } else {
                        ProgressView().controlSize(.large)
                        Text("正在分析…").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // while a new plan is computed the old one stays, slightly dimmed: no flashing spinner
                // while the cover or the start is dragged, the frame under the pointer stands in for the cover (the preview rests on its last frame)
                LockSimView(frames: project.scrubFrame.map { Array(project.frames.dropLast()) + [$0] } ?? project.frames,
                            aspect: project.aspect, replayToken: project.wakeCount, holdOnCover: project.isScrubbing,
                            showsHoverHint: !SnapshotHook.scripted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(project.phase == .planning && project.scrubFrame == nil ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.2), value: project.phase == .planning)
                    .transition(.opacity)
            }
        case .source:
            SourceStage(project: project)
                .transition(.opacity)
        }
    }

}

/// The source picture. In crop mode the window that will become the wallpaper is drawn on it and can be dragged.
private struct SourceStage: View {
    @Bindable var project: Project
    @State private var dragStartFocus: CGPoint?
    /// The kept area when an edge or corner drag began.
    @State private var areaAtBegin: CGRect?

    var body: some View {
        let size = project.source?.size ?? CGSize(width: 16, height: 9)
        GeometryReader { geo in
            // room around the picture for the crop handles
            let fit = fitted(size, in: CGSize(width: geo.size.width - 24, height: geo.size.height - 24))
            ZStack(alignment: .topLeading) {
                if let player = project.player {
                    PlayerView(player: player)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                }
                framing(fit: fit)
            }
            .frame(width: fit.width, height: fit.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .overlay(alignment: .topTrailing) {
                if project.area != Reframe.wholePicture {
                    Button("还原整幅画面", systemImage: "arrow.uturn.backward") {
                        project.beginEdit(); project.area = Reframe.wholePicture; project.endEdit("还原裁切")
                    }
                    .glassButtonStyle(prominent: false)
                    .padding(8)
                    .transition(.opacity)
                }
            }
        }
    }

    /// What is kept (the crop box, with handles on its edges and corners: 11-18 「上下有黑边……没办法裁剪」) and, when
    /// filling the screen, the viewfinder inside it.
    private func framing(fit: CGSize) -> some View {
        let a = project.area
        let kept = CGRect(x: a.minX * fit.width, y: a.minY * fit.height, width: a.width * fit.width, height: a.height * fit.height)
        let f = project.cropFraction
        let finder = CGRect(x: f.minX * fit.width, y: f.minY * fit.height, width: f.width * fit.width, height: f.height * fit.height)
        let filling = project.mode == .crop
        return ZStack(alignment: .topLeading) {
            // cut away by the crop box: dark; outside the viewfinder but kept: dimmed
            Path { p in
                p.addRect(CGRect(origin: .zero, size: fit))
                p.addRect(kept)
            }
            .fill(.black.opacity(0.72), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            if filling {
                Path { p in
                    p.addRect(kept)
                    p.addRoundedRect(in: finder, cornerSize: CGSize(width: 6, height: 6))
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2)
                    .overlay { thirds }
                    .frame(width: finder.width, height: finder.height)
                    .offset(x: finder.minX, y: finder.minY)
                    .allowsHitTesting(false)
            }
            // the picture inside the crop box moves the viewfinder, like moving a photo inside a frame
            Color.clear
                .frame(width: kept.width, height: kept.height)
                .contentShape(Rectangle())
                .offset(x: kept.minX, y: kept.minY)
                .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                    guard filling else { return }
                    if dragStartFocus == nil {
                        dragStartFocus = CGPoint(x: project.focusX, y: project.focusY)
                        project.beginEdit()
                    }
                    let start = dragStartFocus ?? .zero
                    let spareW = kept.width - finder.width, spareH = kept.height - finder.height
                    if spareW > 1 { project.focusX = min(1, max(0, start.x + g.translation.width / spareW)) }
                    if spareH > 1 { project.focusY = min(1, max(0, start.y + g.translation.height / spareH)) }
                }.onEnded { _ in
                    guard dragStartFocus != nil else { return }
                    dragStartFocus = nil
                    project.endEdit("调整取景")
                })
                .grabCursor(active: dragStartFocus != nil)
                .accessibilityElement()
                .accessibilityLabel("取景框")
                .accessibilityHint("拖移画面以选择保留的部分")
            cropHandles(kept: kept, fit: fit)
        }
        .frame(width: fit.width, height: fit.height, alignment: .topLeading)
    }

    fileprivate enum Edge { case left, right, top, bottom }

    /// Yellow brackets at the corners and bars at the edge midpoints, each dragging its edges.
    private func cropHandles(kept: CGRect, fit: CGSize) -> some View {
        let handles: [(edges: [Edge], at: CGPoint, horizontal: Bool?)] = [
            ([.left, .top], CGPoint(x: kept.minX, y: kept.minY), nil), ([.right, .top], CGPoint(x: kept.maxX, y: kept.minY), nil),
            ([.left, .bottom], CGPoint(x: kept.minX, y: kept.maxY), nil), ([.right, .bottom], CGPoint(x: kept.maxX, y: kept.maxY), nil),
            ([.top], CGPoint(x: kept.midX, y: kept.minY), true), ([.bottom], CGPoint(x: kept.midX, y: kept.maxY), true),
            ([.left], CGPoint(x: kept.minX, y: kept.midY), false), ([.right], CGPoint(x: kept.maxX, y: kept.midY), false),
        ]
        // the whole border can be taken, not just the handles (11-18: 「光标在边框的情况下要变成抓手」)
        let grip: CGFloat = 12
        let sides: [(edges: [Edge], rect: CGRect)] = [
            // outward from the line only: a drag starting just inside still moves the viewfinder (11-18 review)
            ([.top], CGRect(x: kept.minX, y: kept.minY - grip, width: kept.width, height: grip + 1)),
            ([.bottom], CGRect(x: kept.minX, y: kept.maxY - 1, width: kept.width, height: grip + 1)),
            ([.left], CGRect(x: kept.minX - grip, y: kept.minY, width: grip + 1, height: kept.height)),
            ([.right], CGRect(x: kept.maxX - 1, y: kept.minY, width: grip + 1, height: kept.height)),
        ]
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.yellow.opacity(0.9), lineWidth: 1.5)
                .frame(width: kept.width, height: kept.height)
                .offset(x: kept.minX, y: kept.minY)
                .allowsHitTesting(false)
            ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                Color.clear
                    .frame(width: side.rect.width, height: side.rect.height)
                    .contentShape(Rectangle())
                    .position(x: side.rect.midX, y: side.rect.midY)
                    .gesture(edgeDrag(side.edges, fit: fit))
                    .cropCursor(side.edges, dragging: areaAtBegin != nil)
                    .accessibilityHidden(true)
            }
            ForEach(Array(handles.enumerated()), id: \.offset) { _, h in
                handleShape(edges: h.edges, horizontal: h.horizontal)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .position(h.at)
                    .gesture(edgeDrag(h.edges, fit: fit))
                    .cropCursor(h.edges, dragging: areaAtBegin != nil)
                    .accessibilityElement()
                    .accessibilityLabel("裁切边")
            }
        }
        .coordinateSpace(name: "stage")
    }

    /// Dragging the given edges of the crop box: ⇧ keeps the proportions, ⌥ moves the opposite side too.
    private func edgeDrag(_ edges: [Edge], fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stage")).onChanged { g in
            if areaAtBegin == nil { areaAtBegin = project.area; project.beginEdit() }
            guard let base = areaAtBegin else { return }
            // like cropping in Photos / Preview: ⇧ keeps the proportions, ⌥ moves the opposite side too
            let keys = NSEvent.modifierFlags
            let next = moved(base, edges: edges, by: CGSize(width: g.translation.width / fit.width,
                                                            height: g.translation.height / fit.height),
                             fromCentre: keys.contains(.option), keepShape: keys.contains(.shift))
            if let next { project.area = next }
        }.onEnded { _ in
            areaAtBegin = nil
            project.endEdit("裁切画面")
            // macOS 14: the exit that came during the drag was ignored; the next hover sets the right one again
            if #unavailable(macOS 15) { NSCursor.arrow.set() }
        }
    }

    @ViewBuilder private func handleShape(edges: [Edge], horizontal: Bool?) -> some View {
        if let horizontal {
            Capsule().fill(Color.yellow)
                .frame(width: horizontal ? 22 : 5, height: horizontal ? 5 : 22)
                .shadow(color: .black.opacity(0.5), radius: 2)
        } else {
            // an L bracket pointing into the picture
            Path { p in
                let l: CGFloat = 14, c: CGFloat = 14
                let dx: CGFloat = edges.contains(.left) ? 1 : -1, dy: CGFloat = edges.contains(.top) ? 1 : -1
                p.move(to: CGPoint(x: c + dx * l, y: c))
                p.addLine(to: CGPoint(x: c, y: c))
                p.addLine(to: CGPoint(x: c, y: c + dy * l))
            }
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }

    /// `base` with the given edges moved by `d` (fractions), at least 10 % each way. `fromCentre` (⌥) moves the
    /// opposite edges the other way; `keepShape` (⇧) keeps base's proportions, the other side following around the fixed
    /// corner, or the centre of the edge (both with ⌥). Without either, a side simply stops at the picture's edge; with
    /// them, a drag past it gives the largest box that still fits, still centred / in proportion (11-18 review: it
    /// used to stop at the last event that fitted, or drift off centre).
    private func moved(_ base: CGRect, edges: [Edge], by d: CGSize, fromCentre: Bool, keepShape: Bool) -> CGRect? {
        let least: CGFloat = 0.1, eps: CGFloat = 1e-6
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        func candidate(_ d: CGSize) -> CGRect {
            // growth of the width and height (the dragged side outwards is positive)
            var dw: CGFloat = edges.contains(.right) ? d.width : edges.contains(.left) ? -d.width : 0
            var dh: CGFloat = edges.contains(.bottom) ? d.height : edges.contains(.top) ? -d.height : 0
            if fromCentre { dw *= 2; dh *= 2 }
            var w = max(least, base.width + dw), h = max(least, base.height + dh)
            if keepShape {
                let ratio = base.width / base.height
                if horizontal && (!vertical || abs(dw / base.width) >= abs(dh / base.height)) { h = w / ratio } else { w = h * ratio }
                if w < least { w = least; h = w / ratio }
                if h < least { h = least; w = h * ratio }
            }
            // the fixed side stays, or the centre with ⌥; an edge handle with ⇧ grows about its middle
            let x: CGFloat = fromCentre || (keepShape && !horizontal) ? base.midX - w / 2
                : edges.contains(.left) ? base.maxX - w : base.minX
            let y: CGFloat = fromCentre || (keepShape && !vertical) ? base.midY - h / 2
                : edges.contains(.top) ? base.maxY - h : base.minY
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func fits(_ r: CGRect) -> Bool {
            r.minX >= -eps && r.minY >= -eps && r.maxX <= 1 + eps && r.maxY <= 1 + eps
        }
        let wanted = candidate(d)
        if !fromCentre && !keepShape {
            let r = wanted.intersection(whole)
            return r.width >= least - eps && r.height >= least - eps ? r : nil
        }
        if fits(wanted) { return wanted }
        // the furthest part of this drag that still fits (the base fits, so there is one)
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let k = (lo + hi) / 2
            if fits(candidate(CGSize(width: d.width * k, height: d.height * k))) { lo = k } else { hi = k }
        }
        let r = candidate(CGSize(width: d.width * lo, height: d.height * lo))
        return fits(r) ? r : nil
    }

    private var thirds: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / max(1, size.width), box.height / max(1, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - verdict

private extension Project.Verdict.Level {
    var color: Color { switch self { case .good: .green; case .caution: .orange; case .bad: .red } }
    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }
}

private struct VerdictHeader: View {
    let verdict: Project.Verdict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: verdict.level.symbol).font(.system(size: 22)).foregroundStyle(verdict.level.color)
                .symbolEffect(.bounce, value: reduceMotion ? .good : verdict.level)
                .accessibilityHidden(true)
            Text(verdict.title).font(.headline)
            Spacer(minLength: 0)
            if let advice = verdict.advice { InfoButton(text: advice) }
        }
    }
}

/// The two checks in words, each on a three-zone bar with a marker: where the value sits matters, not the number.
private struct ChecksDetail: View {
    let report: WindowReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            meter("相邻两帧的差别", value: report.stepDiffs.max() ?? 0,
                  zones: [(SegmentPlanner.smoothStep, "平滑"), (SegmentPlanner.jumpyStep, "略有跳动"), (40, "跳动明显")])
            meter("明暗闪烁", value: report.reversalMean,
                  zones: [(WindowAnalysis.reversalWarning, "很少"), (WindowAnalysis.reversalWarning * 2, "可能察觉"), (45, "明显")])
        }
    }

    private static let colors: [Color] = [.green, .orange, .red]

    /// `zones`: upper bound and word for green, orange, red; the last bound is the right end of the bar.
    private func meter(_ title: String, value: Double, zones: [(Double, String)]) -> some View {
        let zone = zones.firstIndex(where: { value <= $0.0 }) ?? zones.count - 1
        let end = zones.last!.0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(zones[zone].1).fontWeight(.semibold).foregroundStyle(Self.colors[zone])
                    .contentTransition(.interpolate)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(zones.indices, id: \.self) { i in
                            let from = i == 0 ? 0 : zones[i - 1].0
                            Capsule().fill(Self.colors[i].opacity(i == zone ? 0.9 : 0.28))
                                .frame(width: max(0, (zones[i].0 - from) / end * w - 2))
                        }
                    }
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .offset(x: min(max(0, value / end), 1) * (w - 9))
                }
            }
            .frame(height: 9)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(zones[zone].1)
    }
}

/// A small ⓘ that opens its explanation in a popover: visible, so people know there is more, and quiet until asked.
private struct InfoButton: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("说明")
        .accessibilityLabel("说明")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(14)
        }
    }
}

// MARK: - sidebar

/// Only what a first-time user needs; how the frames were picked is one click away for the curious.
private struct Sidebar: View {
    @Bindable var project: Project

    var body: some View {
        Form {
            Section {
                Picker(selection: $project.preset) {
                    Section("iPhone") { ForEach(ScreenPreset.iPhones) { presetLabel($0) } }
                    Section("iPad") { ForEach(ScreenPreset.iPads) { presetLabel($0) } }
                    Divider()
                    presetLabel(.custom)
                } label: {
                    Text("机型")
                }
                .pickerStyle(.menu)
                if project.preset.rotates {
                    Picker("方向", selection: $project.landscape) {
                        Label("竖放", systemImage: "ipad").tag(false)
                        Label("横放", systemImage: "ipad.landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if project.preset.id == "custom" {
                    LabeledContent("宽 × 高") {
                        HStack(spacing: 4) {
                            TextField("宽", value: $project.customWidth, format: .number).frame(width: 64)
                            Text("×").foregroundStyle(.secondary)
                            TextField("高", value: $project.customHeight, format: .number).frame(width: 64)
                        }
                        .labelsHidden()
                    }
                }
                FitPicker(project: project)
                    .padding(.vertical, 2)
            } header: {
                Text("屏幕")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !project.preset.verified {
                        Text("这个机型还没有在真机上测过。")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)          // line up with the rows' text, like the section header
            }

            Section {
                if let verdict = project.verdict, let report = project.report {
                    VerdictHeader(verdict: verdict)
                        .padding(.vertical, 4)
                        .opacity(project.phase == .planning ? 0.45 : 1)
                        .overlay(alignment: .topTrailing) {
                            if project.phase == .planning { ProgressView().controlSize(.small).padding(.top, 4) }
                        }
                        .animation(.easeOut(duration: 0.15), value: project.phase == .planning)
                    Text(String(format: "封面前 %.1f 秒 · %.1f× 快放", project.span, project.speedUp))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if !project.startIsAuto, project.smoothStart != nil { smoothestRow }
                    if let notice = project.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    if let why = project.planFailed { failedRow(why) }
                } else if let why = project.planFailed {
                    failedRow(why)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在分析…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("动画")
            } footer: {
                // said where people look, not in a help page (#0018): the preview is an imitation, and long stretches flash
                Text("锁屏只用约 0.75 秒播 10 帧：起点离封面越远，快放越快，画面变化快时会跳动。手机会在帧之间自动过渡，实际效果以手机为准。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            if let report = project.report, project.verdict != nil {
                Section {
                    FrameStrip(project: project)
                    ChecksDetail(report: report)
                } header: {
                    HStack {
                        Text("锁屏会播的 10 帧")
                        Spacer()
                        InfoButton(text: howItWorks)
                    }
                }
            }

            if let result = project.lastExport {
                Section("最近导出") {
                    LabeledContent("文件") { Text(result.packageURL.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                    HStack {
                        Button("隔空投送…", systemImage: "dot.radiowaves.up.forward") {
                            if let why = project.airDrop(result.packageURL) { project.phase = .failed(why) }
                        }
                        Menu {
                            Button("添加到「照片」", systemImage: "photo.badge.plus") {
                                if let why = project.addToPhotos(result.packageURL) { project.phase = .failed(why) }
                            }
                            Button("存储到…", systemImage: "square.and.arrow.down") {
                                saveWallpaperPanel(project) { project.phase = .failed($0) }
                            }
                            if let saved = project.savedFile {
                                Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                            }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(project.isExporting)
    }

    private var howItWorks: String {
        """
        唤醒\(project.preset.deviceName)时，锁屏用约 0.75 秒把这 10 帧先快后慢播一遍，停在封面上。
        10 帧从起点到封面均匀取，所以起点在封面前 X 秒就是 X ÷ 0.75 倍快放：慢的画面像延时摄影，快的画面会跳动。
        预览只模拟动画，实际效果以设备为准。
        """
    }

    private func presetLabel(_ p: ScreenPreset) -> some View {
        Label(p.name, systemImage: p.symbol).tag(p)
    }

    private var smoothestRow: some View {
        Button("回到最顺的起点", systemImage: "arrow.uturn.backward") { project.useSmoothestStart() }
            .help("起点回到绿色标记，之后换封面时起点会跟着找最远还顺的地方")
    }

    private func failedRow(_ why: String) -> some View {
        HStack {
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Spacer()
            Button("重试", systemImage: "arrow.clockwise") { project.replan(immediately: true) }.controlSize(.small)
        }
    }
}

/// After an export: what to do next, in order, with the one step the Mac can do as a button.
private struct ExportDoneSheet: View {
    let project: Project
    let result: BuildResult
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                // what was made, not a generic check: the cover as the device will show it
                if let cover = project.frames.last {
                    let h: CGFloat = project.aspect > 1 ? 54 : 76
                    Image(decorative: cover, scale: 1).resizable()
                        .frame(width: h * CGFloat(project.aspect), height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.25)))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                                .offset(x: 6, y: 6)
                        }
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("壁纸做好了").font(.title2.weight(.semibold))
                    Text(result.packageURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                step(1, "发送到 \(project.preset.deviceName)", detail: nil) {
                    HStack(spacing: 8) {
                        Button("隔空投送…", systemImage: "dot.radiowaves.up.forward") { problem = project.airDrop(result.packageURL) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .help("\(project.preset.deviceName) 接受后，壁纸会存入「照片」")
                        Button("添加到「照片」", systemImage: "photo.badge.plus") { problem = project.addToPhotos(result.packageURL) }
                            .help("开启了 iCloud 照片时，会同步到 \(project.preset.deviceName)")
                    }
                }
                step(2, "在 \(project.preset.deviceName) 上设为壁纸", detail: "照片 › 分享 › 用作壁纸，打开左下角的「实况」")
            }
            HStack {
                Button("存储到…", systemImage: "square.and.arrow.down") { saveWallpaperPanel(project) { problem = $0 } }
                    .help("把壁纸存成文件。做好的壁纸先放在临时文件夹，不存也不占磁盘")
                if let saved = project.savedFile {
                    Button("已存储 · 在访达中显示", systemImage: "checkmark.circle") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .help(saved.path)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .alert("无法完成操作", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("好") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func step(_ n: Int, _ title: String, detail: String?) -> some View {
        step(n, title, detail: detail) { EmptyView() }
    }

    private func step<Accessory: View>(_ n: Int, _ title: String, detail: String?, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.callout.weight(.bold)).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.25), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                accessory().padding(.top, 2)
            }
        }
    }
}

/// The planned frames, numbered, the cover last. Edges fade where there is more to scroll to.
private struct FrameStrip: View {
    @Bindable var project: Project
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewWidth: CGFloat = 0

    private let height: CGFloat = 44

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(project.frames.enumerated()), id: \.offset) { i, image in
                        frame(i, image).id(i)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: StripMetrics.self, value: [g.frame(in: .named("strip")).minX, g.size.width])
                })
            }
            .coordinateSpace(name: "strip")
            .background(GeometryReader { g in Color.clear.onAppear { viewWidth = g.size.width }.onChange(of: g.size.width) { _, w in viewWidth = w } })
            .onPreferenceChange(StripMetrics.self) { m in
                if m.count == 2 { offset = m[0]; contentWidth = m[1] }
            }
            .mask(fadeMask)
            .onChange(of: project.pickedFrame) { _, i in
                guard let i else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(height: height + 16)
    }

    private var fadeMask: some View {
        let left = offset < -1, right = offset + contentWidth > viewWidth + 1
        return LinearGradient(stops: [
            .init(color: left ? .clear : .black, location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88),
            .init(color: right ? .clear : .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func frame(_ i: Int, _ image: CGImage) -> some View {
        let isCover = i == project.frames.count - 1
        let picked = project.pickedFrame == i
        let name = isCover ? "封面" : "\(i + 1)"
        return Button {
            project.showFrameDetails(i)
        } label: {
            VStack(spacing: 3) {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(project.aspect, contentMode: .fill)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCover ? Color.yellow : (picked ? .white : .white.opacity(0.1)), lineWidth: isCover || picked ? 2 : 1))
                Text(name).font(.caption2.weight(isCover || picked ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isCover ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(picked ? .primary : .secondary))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCover ? "封面" : "第 \(i + 1) 帧")
        .accessibilityHint("在视频中显示这一帧")
    }
}

private struct StripMetrics: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { let n = nextValue(); if !n.isEmpty { value = n } }
}

private extension SourceStage.Edge {
    @available(macOS 15, *)
    static func position(_ edges: [Self]) -> FrameResizePosition {
        switch (edges.contains(.left), edges.contains(.right), edges.contains(.top), edges.contains(.bottom)) {
        case (true, _, true, _): .topLeading
        case (_, true, true, _): .topTrailing
        case (true, _, _, true): .bottomLeading
        case (_, true, _, true): .bottomTrailing
        case (true, _, _, _): .leading
        case (_, true, _, _): .trailing
        case (_, _, true, _): .top
        default: .bottom
        }
    }
}

private extension View {
    /// The system's frame-resize pointer for a crop box edge or corner (arrows pointing the ways it moves, like
    /// cropping in Photos). macOS 14 has no diagonal one, corners get the crosshair; there the cursor is set rather
    /// than pushed (overlapping hover areas and views going away unbalanced the stack, 11-18 review) and is left alone
    /// while a drag is on.
    @ViewBuilder
    func cropCursor(_ edges: [SourceStage.Edge], dragging: Bool) -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(.frameResize(position: SourceStage.Edge.position(edges)))
        } else {
            self.onHover { inside in
                guard !dragging else { return }
                let cursor: NSCursor = edges.count > 1 ? .crosshair
                    : edges.contains(.left) || edges.contains(.right) ? .resizeLeftRight : .resizeUpDown
                (inside ? cursor : NSCursor.arrow).set()
            }
        }
    }
}
