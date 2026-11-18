import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit

/// The bare video picture, no transport controls (LiveWall: the trim bar is the control surface).
public struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    public init(player: AVPlayer) { self.player = player }

    public func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    public func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    public final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        public override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        public required init?(coder: NSCoder) { fatalError("not used") }

        public override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
