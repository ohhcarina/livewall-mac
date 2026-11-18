#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Liquid Glass on macOS / iOS 26 and later; the closest material before (macOS 14/15, iOS 18).
public extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, iOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

#if os(macOS)
/// Pointer shapes: the system ones on macOS 15+, NSCursor on 14 (only while hovering, never popped mid-drag).
public extension View {
    @ViewBuilder
    func grabCursor(active: Bool) -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(active ? .grabActive : .grabIdle)
        } else {
            self.onHover { inside in
                if inside { NSCursor.openHand.push() } else if !active { NSCursor.pop() }
            }
        }
    }

    @ViewBuilder
    func resizeCursor() -> some View {
        if #available(macOS 15, *) {
            self.pointerStyle(.columnResize)
        } else {
            self.onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
    }
}
#endif
