import AppKit
import SwiftUI

/// 锁屏 / 视频, over the canvas. On macOS 27 this is AppKit's segmented control with the `tabs` role: the system's
/// switch whose selection slides and stretches across (Xcode's navigator/inspector switch). SwiftUI's segmented
/// `Picker` has no such role and its selection jumps. Older systems get the plain segmented `Picker`.
struct ViewModeSwitch: View {
    @Binding var selection: Project.ViewMode

    var body: some View {
        if #available(macOS 27, *) {
            // SwiftUI hands its own control size to the AppKit control: set it here, or it comes out small and square
            TabsSegmentedControl(selection: $selection).controlSize(.extraLarge).fixedSize()
        } else {
            Picker("显示", selection: $selection) {
                Text("锁屏").tag(Project.ViewMode.lockScreen)
                Text("视频").tag(Project.ViewMode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
        }
    }
}

@available(macOS 27, *)
private struct TabsSegmentedControl: NSViewRepresentable {
    @Binding var selection: Project.ViewMode

    private static let modes: [Project.ViewMode] = [.lockScreen, .source]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["锁屏", "视频"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.role = .tabs
        control.controlSize = .extraLarge
        control.setAccessibilityLabel("显示")
        control.selectedSegment = Self.modes.firstIndex(of: selection) ?? 0
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.modes.firstIndex(of: selection) ?? 0
        // changed elsewhere (menu, ⌘1/⌘2, dragging in the trim bar): slide there like a click would
        if control.selectedSegment != index { Self.slide(control, to: index) }
    }

    /// The slide only runs inside an animation group that allows implicit animation: through `animator()` alone, or
    /// from SwiftUI's own animation transaction, the selection jumps (measured in a window recording).
    static func slide(_ control: NSSegmentedControl, to index: Int) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { control.selectedSegment = index; return }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            control.animator().selectedSegment = index
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Project.ViewMode>
        init(selection: Binding<Project.ViewMode>) { self.selection = selection }

        /// A click slides by itself (with the real SDK recorded in the binary; see build-app.sh).
        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            selection.wrappedValue = TabsSegmentedControl.modes[max(0, sender.selectedSegment)]
        }
    }
}
