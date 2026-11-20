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
        // `LIVEWALL_DRAG=4` drags the cover on the lock screen that many times, each once the picture for the last one is
        // up (the calls the trim bar makes, 240 pointer moves in 4 s, back and forth), and says on stderr how each went:
        // how long the moves took (over 4 s: the main thread could not keep up) and how many pictures reached the
        // preview, and when the picture, the editing copy, the settled automatic start and the whole start search arrived. 11-19: a build nobody had
        // dragged in showed no picture from the second drag on.
        if let rounds = ProcessInfo.processInfo.environment["LIVEWALL_DRAG"].flatMap({ Int($0) }) {
            let launch = Date()
            func say(_ text: String) {
                FileHandle.standardError.write(Data(String(format: "[%6.1f s] %@\n", Date().timeIntervalSince(launch), text).utf8))
            }
            // what arrives when, all along
            Task { @MainActor in
                var picture = false, copy = false, complete = false, planning = false, settling = false
                var lastFailure: String?
                while true {
                    let p = !project.answersAreStale && project.planIsCurrent, c = project.exactPlayer != nil
                    let s = project.searchIsComplete
                    if p != picture { picture = p; if p { say(String(format: "picture up (start %.2f s before the cover)", project.span)) } }
                    if project.phase == .planning, !planning { planning = true } else if project.phase != .planning { planning = false }
                    if c != copy { copy = c; if c { say("editing copy in use") } }
                    if project.startIsSettling != settling {
                        settling = project.startIsSettling
                        say(settling ? "start settling" : String(format: "start settled (%.2f s before the cover, colour bar %@)",
                                                                  project.span, project.feelBands == nil ? "missing" : "in"))
                    }
                    if let failed = project.planFailed, failed != lastFailure { lastFailure = failed; say("plan failed: \(failed)") }
                    if s != complete { complete = s; if s { say(String(format: "start search complete (smoothest %.2f s before the cover)", project.rangeEnd - (project.smoothStart ?? project.rangeEnd))) } }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            for round in 0..<rounds {
                for _ in 0..<1200 where project.source == nil || !project.planIsCurrent || project.answersAreStale {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(2))
                let began = Date(), span = project.span, onCopy = project.exactPlayer != nil
                var pictures = 0, last = project.scrubFrame
                // `LIVEWALL_DRAG_WHAT=start`: the start handle instead, out to 3, 9, 3, 9 ... s before the cover
                let start = ProcessInfo.processInfo.environment["LIVEWALL_DRAG_WHAT"] == "start"
                let from = project.rangeStart, to = max(0, project.rangeEnd - (round % 2 == 0 ? 3 : 9))
                project.pause()
                project.beginEdit()
                if start { project.startIsAuto = false }
                for k in 0..<240 {
                    if start {
                        project.rangeStart = from + (to - from) * Double(k + 1) / 240
                        project.scrub(at: project.rangeStart)
                    } else {
                        project.moveCover(to: project.rangeEnd + (round % 2 == 0 ? -0.05 : 0.03), keeping: span)
                        project.scrub(at: project.rangeEnd)
                    }
                    try? await Task.sleep(for: .milliseconds(16))
                    if project.scrubFrame !== last { pictures += 1; last = project.scrubFrame }
                }
                say(String(format: "drag %d (%@) on the %@: 240 moves in %.1f s, %d pictures", round + 1, start ? "start" : "cover",
                           onCopy ? "copy" : "original", Date().timeIntervalSince(began), pictures))
                // held still a moment before letting go, as people do (`LIVEWALL_DRAG_REST` ms, default 0)
                if let rest = ProcessInfo.processInfo.environment["LIVEWALL_DRAG_REST"].flatMap({ Int($0) }) {
                    try? await Task.sleep(for: .milliseconds(rest))
                }
                project.endScrub(keepPicture: !start)
                project.endEdit(start ? "调整起点" : "调整封面")
            }
        }
        let exportDir = ProcessInfo.processInfo.environment["LIVEWALL_EXPORT"]
        guard outputPath != nil || exportDir != nil else { return }
        for _ in 0..<240 {                                   // up to 60 s for the source to load and the preview to build
            try? await Task.sleep(nanoseconds: 250_000_000)
            if project.phase == .ready, !project.frames.isEmpty { break }
        }
        // the whole start search, so a scripted export always gets the final automatic start (#0033: the first picture
        // comes with the start the nearest 2 s allow)
        for _ in 0..<480 where !project.searchIsComplete { try? await Task.sleep(nanoseconds: 250_000_000) }
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
