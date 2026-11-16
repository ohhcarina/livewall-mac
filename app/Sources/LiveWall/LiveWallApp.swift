import AppKit
import SwiftUI

@main
struct LiveWallApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // lets `swift run LiveWall` show a normal, focusable window; the packaged .app is regular anyway
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        Project.removeStaleExports()
    }

    var body: some Scene {
        // one editing window: menu commands always act on it, and Finder's Open With reuses it
        Window("LiveWall", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1180, height: 820)
        .commands { LiveWallCommands() }
    }
}

/// One window holds the whole session; closing it ends the app, so there is no windowless state where ⌘N and ⌘E
/// have nothing to act on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The window's project, for menu commands.
struct ProjectKey: FocusedValueKey {
    typealias Value = Project
}

extension FocusedValues {
    var project: Project? {
        get { self[ProjectKey.self] }
        set { self[ProjectKey.self] = newValue }
    }
}

/// Menus. Playback keys (space, arrows, I, O) are handled by the canvas, not bound here: as menu key equivalents
/// they would also fire while typing in the sidebar's text fields. The menu items show where they are.
struct LiveWallCommands: Commands {
    @FocusedValue(\.project) private var project

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // choosing a video starts a new wallpaper, so it is 新建 (the toolbar's +), not 打开
            Button("新建…", systemImage: "plus") { NotificationCenter.default.post(name: .openVideo, object: nil) }
                .keyboardShortcut("n")
                .disabled(project?.isExporting ?? false)
            // SwiftUI's Window scene has no File › Open Recent of its own. Read on every rebuild of the menus;
            // `sourceURL` is read so the list refreshes after an open.
            let _ = project?.sourceURL
            let recent = NSDocumentController.shared.recentDocumentURLs
            Menu("打开最近使用") {
                ForEach(recent, id: \.self) { url in
                    Button(url.lastPathComponent) { project?.open(url) }
                }
                if !recent.isEmpty { Divider() }
                Button("清除菜单") { NSDocumentController.shared.clearRecentDocuments(nil) }
                    .disabled(recent.isEmpty)
            }
            .disabled(project == nil || (project?.isExporting ?? false))
        }
        CommandGroup(replacing: .importExport) {
            Button("导出壁纸", systemImage: "square.and.arrow.up") { NotificationCenter.default.post(name: .exportWallpaper, object: nil) }
                .keyboardShortcut("e")
                .disabled(!(project?.canExport ?? false))
        }
        CommandGroup(before: .toolbar) {
            // a picker, so the menu ticks the current view
            Picker("显示", selection: Binding(get: { project?.viewMode ?? .lockScreen }, set: { project?.viewMode = $0 })) {
                Text("锁屏预览").tag(Project.ViewMode.lockScreen).keyboardShortcut("1")
                Text("视频").tag(Project.ViewMode.source).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(project?.source == nil)
            Divider()
        }
        CommandMenu("播放") {
            let loaded = project?.source != nil
            Button(project?.viewMode == .lockScreen ? "播放锁屏动画（空格键）" : "播放/暂停（空格键）", systemImage: "play.fill") {
                guard let project else { return }
                if project.viewMode == .lockScreen { project.wake() } else { project.togglePlay() }
            }
            .disabled(!loaded)
            Button("上一帧（←）", systemImage: "backward.frame") { project?.viewMode = .source; project?.step(frames: -1) }
                .disabled(!loaded)
            Button("下一帧（→）", systemImage: "forward.frame") { project?.viewMode = .source; project?.step(frames: 1) }
                .disabled(!loaded)
            Divider()
            Button("将起点设在这里（I）", systemImage: "arrow.right.to.line") { project?.setStartToPlayhead() }
                .disabled(!loaded)
            Button("将封面设在这里（O）", systemImage: "arrow.left.to.line") { project?.setEndToPlayhead() }
                .disabled(!loaded)
            Divider()
            Button("回到最顺的起点", systemImage: "arrow.uturn.backward") { project?.useSmoothestStart() }
                .disabled(!loaded || project?.startIsAuto != false)
        }
    }
}

extension Notification.Name {
    static let openVideo = Notification.Name("LiveWall.openVideo")
    static let exportWallpaper = Notification.Name("LiveWall.exportWallpaper")
}
