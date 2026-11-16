import AppKit
import SwiftUI

/// Development aid: `LIVEWALL_SNAPSHOT=/path/out.png LiveWall <video>` writes a PNG of the app's own window once the
/// preview is ready and quits. It renders the window's views directly, so no screen recording permission is needed and
/// nothing outside the window is captured. `LIVEWALL_EXPORT=/dir` additionally exports `app-export.pvt` (or
/// `$LIVEWALL_EXPORT_NAME.pvt`) there first (`LIVEWALL_EXPORT=temp` runs the app's own flow into the temporary folder) (alone,
/// without a snapshot path, it exports and leaves the window open on the finished-export sheet).
@MainActor
enum SnapshotHook {
    static var outputPath: String? { ProcessInfo.processInfo.environment["LIVEWALL_SNAPSHOT"] }

    /// Started in a `LIVEWALL_STATE`: the pointer is wherever the person left it, so hover effects are ignored and
    /// the window looks the same in every capture.
    static let scripted = ProcessInfo.processInfo.environment["LIVEWALL_STATE"] != nil

    static func run(project: Project) async {
        // `LIVEWALL_STATE=source,crop,frame` starts in that state (to look at screens that need clicks to reach)
        if let state = ProcessInfo.processInfo.environment["LIVEWALL_STATE"]?.split(separator: ","), !state.isEmpty {
            for _ in 0..<40 where project.source == nil || project.phase == .loading { try? await Task.sleep(nanoseconds: 250_000_000) }
            if state.contains("source") { project.viewMode = .source }
            if state.contains("crop") { project.mode = .crop }
            if state.contains("frame") {                     // as if frame 4 was clicked in the trim bar
                for _ in 0..<80 where project.times.count < 4 { try? await Task.sleep(nanoseconds: 250_000_000) }
                project.showFrameDetails(3)
            }
            if state.contains("far") {                       // as if the start was dragged 6 s before the cover
                for _ in 0..<240 where project.smoothStart == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                project.startIsAuto = false
                project.rangeStart = max(0, project.rangeEnd - 6)
                for _ in 0..<40 where project.phase != .ready { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if state.contains("fit") {                       // for recording: switch 完整/铺满 every 3 s, 4 times
                for _ in 0..<240 where project.filmstrip.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                for _ in 0..<4 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    project.mode = project.mode == .crop ? .squeeze : .crop
                }
            }
            if state.contains("wake") {                      // for recording the window: wake the preview every 4 s once
                for _ in 0..<240 where project.phase != .ready || project.frames.isEmpty || project.filmstrip.isEmpty {
                    try? await Task.sleep(nanoseconds: 250_000_000)       // everything loaded, so only the preview moves
                }
                for _ in 0..<4 {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    project.wake()
                }
            }
        }
        let exportDir = ProcessInfo.processInfo.environment["LIVEWALL_EXPORT"]
        guard outputPath != nil || exportDir != nil else { return }
        for _ in 0..<240 {                                   // up to 60 s for the source to load and the preview to build
            try? await Task.sleep(nanoseconds: 250_000_000)
            if project.phase == .ready, !project.frames.isEmpty { break }
        }
        if let dir = exportDir {                             // also run the export, to check the whole flow
            let name = ProcessInfo.processInfo.environment["LIVEWALL_EXPORT_NAME"] ?? "app-export"
            if dir == "temp" { project.exportToTemporaryFolder() }      // the app's own flow: render first, pick a place after
            else { project.export(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).pvt")) }
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if project.lastExport != nil { break }
                if case .failed = project.phase { break }
            }
        }
        guard let path = outputPath else { return }          // export only: leave the window up (its sheet) for a window capture
        try? await Task.sleep(nanoseconds: 1_300_000_000)    // let the lock-screen simulation reach a mid frame
        if let item = project.player?.currentItem {
            print("player item status \(item.status.rawValue) (1 = ready), presentation size \(item.presentationSize)")
        }
        // the content view's superview is the window's frame view: includes the title bar and toolbar
        guard let content = NSApp.windows.first?.contentView, let view = content.superview ?? Optional(content),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}
