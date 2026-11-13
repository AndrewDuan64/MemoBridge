import AVFoundation
import Foundation

private enum PlaybackTestError: Error { case failed(String) }

@main
struct AudioPlaybackTests {
    @MainActor private static func waitFor(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return predicate()
    }

    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PlaybackTestError.failed(message) }
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MemoBridge-playback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }

        let playback = AudioPlaybackController()
        playback.load(nil)
        try check(!playback.isReady && !playback.isPlaying, "Nil audio should be unavailable")
        playback.load(audioURL)
        guard await waitFor({ playback.isReady || playback.errorMessage != nil }), playback.isReady else {
            throw PlaybackTestError.failed("Unable to load generated WAV: \(playback.errorMessage ?? "timed out")")
        }
        try check(playback.duration > 1.9 && playback.duration < 2.1, "Unexpected audio duration")
        playback.seek(to: 1)
        try check(abs(playback.elapsed - 1) < 0.01, "Seek should update the time")
        playback.seek(to: -10)
        try check(playback.elapsed == 0, "Seek should clamp to the beginning")
        playback.togglePlayback()
        try check(playback.isPlaying, "Playback should start")
        guard await waitFor({ playback.elapsed > 0.15 || playback.errorMessage != nil }), playback.errorMessage == nil else {
            throw PlaybackTestError.failed("Playback did not advance: \(playback.errorMessage ?? "timed out")")
        }
        playback.togglePlayback()
        try check(!playback.isPlaying, "Playback should pause")
        playback.seek(to: 999)
        try check(playback.elapsed == playback.duration, "Seek should clamp to the end")
        playback.togglePlayback()
        try check(playback.isPlaying, "Replay should start")
        guard await waitFor({ playback.elapsed < 1.5 || playback.errorMessage != nil }), playback.errorMessage == nil else {
            throw PlaybackTestError.failed("Replay did not restart")
        }
        playback.load(directory.appendingPathComponent("missing.wav"))
        guard await waitFor({ playback.errorMessage != nil }) else { throw PlaybackTestError.failed("Missing audio should report an error") }
        try check(!playback.isReady && !playback.isPlaying, "Missing audio should not play")
        playback.load(audioURL)
        guard await waitFor({ playback.isReady }) else { throw PlaybackTestError.failed("Reload failed") }
        playback.togglePlayback()
        playback.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        try check(!playback.isReady && !playback.isPlaying && playback.elapsed == 0 && playback.duration == 0 && playback.errorMessage == nil,
                  "Stopping should clear state and ignore stale callbacks")
        print("Audio playback: load, progress, seek, pause, replay, failure, switching and cleanup passed")
    }
}
