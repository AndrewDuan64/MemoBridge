import AVFoundation
import SwiftUI

/// Owns one player and releases its observers whenever the selected audio changes.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var generation = UUID()

    func load(_ url: URL?) {
        stop()
        guard let url else { return }
        let generation = self.generation
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.generation == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.updateDuration(from: item)
                case .failed:
                    self.isPlaying = false
                    self.isReady = false
                    self.errorMessage = "Audio could not be played. Check that it is downloaded and accessible."
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak item] time in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == generation else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.elapsed = max(0, seconds) }
                self.updateDuration(from: item)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.isPlaying = false
                if self.duration > 0 { self.elapsed = self.duration }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.isPlaying = false
                self.isReady = false
                self.errorMessage = "Playback stopped because the audio could not be read."
            }
        }
    }

    func togglePlayback() {
        guard let player, isReady else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, elapsed >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player, isReady, duration > 0, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration)
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        generation = UUID()
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        isReady = false
        isPlaying = false
        elapsed = 0
        duration = 0
        errorMessage = nil
    }

    private func updateDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        if seconds.isFinite && seconds > 0 { duration = seconds }
    }

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL?
    @StateObject private var playback = AudioPlaybackController()
    @State private var dragging = false
    @State private var dragTime: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Button { playback.togglePlayback() } label: {
                Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(!playback.isReady)
            if let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if audioURL == nil {
                Text("Audio unavailable").font(.caption).foregroundStyle(.secondary)
            } else {
                Slider(value: Binding(
                    get: { dragging ? dragTime : min(playback.elapsed, max(playback.duration, 0.01)) },
                    set: { value in
                        dragTime = value
                        if !dragging { playback.seek(to: value) }
                    }
                ), in: 0...max(playback.duration, 0.01), onEditingChanged: { editing in
                    if editing {
                        dragTime = playback.elapsed
                        dragging = true
                    } else {
                        playback.seek(to: dragTime)
                        dragging = false
                    }
                })
                .disabled(!playback.isReady || playback.duration <= 0)
                .accessibilityLabel("Playback position")
                Text("\(audioTime(dragging ? dragTime : playback.elapsed)) / \(audioTime(playback.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { playback.load(audioURL) }
        .onChange(of: audioURL) { playback.load($0) }
        .onDisappear { playback.stop() }
    }
}

private func audioTime(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0:00" }
    let seconds = Int(min(value, Double(Int.max / 2)))
    if seconds >= 3600 {
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
