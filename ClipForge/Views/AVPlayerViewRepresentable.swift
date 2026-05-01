import SwiftUI
import AVKit
import AppKit

/// SwiftUI wrapper around AppKit's `AVPlayerView`. Avoids the SwiftUI
/// `VideoPlayer<Content>` generic which crashes during class-metadata init
/// in some macOS 26 builds.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .floating

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
