import SwiftUI
import AVKit
import Combine

/// AVPlayer-backed video player that tracks current time as a binding so the
/// transcript and clip list can highlight what's playing, and so external code
/// can scrub by writing to the binding.
struct MasterPlayerView: View {
    let url: URL
    @Binding var currentTime: Double
    let duration: Double

    @State private var player: AVPlayer
    @State private var timeObserver: Any?
    @State private var isPlaying: Bool = false

    init(url: URL, currentTime: Binding<Double>, duration: Double) {
        self.url = url
        self._currentTime = currentTime
        self.duration = duration
        self._player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 4) {
            AVPlayerViewRepresentable(player: player)
                .frame(minHeight: 280)
                .background(Color.black)
                .cornerRadius(6)

            // Compact transport row (the player view also has its own controls).
            HStack(spacing: 12) {
                Text(formatTimecode(currentTime))
                    .font(.system(.caption, design: .monospaced))
                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            currentTime = newValue
                            seek(to: newValue)
                        }
                    ),
                    in: 0...max(duration, 0.01)
                )
                Text(formatTimecode(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            attachTimeObserver()
        }
        .onDisappear {
            if let obs = timeObserver { player.removeTimeObserver(obs) }
            timeObserver = nil
            player.pause()
        }
    }

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
        }
    }

    private func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Public seek + play helper for parents (clip "Play" button).
    func playFrom(seconds start: Double, durationLimit: Double?) {
        seek(to: start)
        player.play()
        if let durationLimit, durationLimit > 0 {
            let stopAt = start + durationLimit
            DispatchQueue.main.asyncAfter(deadline: .now() + durationLimit) {
                if currentTime + 0.05 >= stopAt {
                    player.pause()
                }
            }
        }
    }
}

/// Convenience: a coordinator object that holds the player so non-view code
/// can drive playback (e.g. "Play this clip" buttons).
@MainActor
final class PlayerController: ObservableObject {
    @Published var currentTime: Double = 0
    let player: AVPlayer

    init(url: URL) {
        self.player = AVPlayer(url: url)
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    /// Swap the current item to a different URL (used when toggling between
    /// the source master and the rendered stitched output).
    func replace(url: URL) {
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = 0
    }

    func playClip(start: Double, end: Double) {
        seek(to: start)
        player.play()
        let duration = max(0, end - start)
        if duration > 0 {
            // Schedule a pause near end. (Approximate; the periodic observer
            // would be more precise but this is sufficient for preview.)
            let stopWork = DispatchWorkItem { [weak self] in
                self?.player.pause()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stopWork)
        }
    }
}
