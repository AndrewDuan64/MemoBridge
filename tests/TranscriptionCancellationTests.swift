import AVFoundation
import Darwin
import Foundation

private enum Failure: Error { case message(String) }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.message(message) }
}

@main
struct TranscriptionCancellationTests {
    @MainActor static func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while Date() < limit {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    static func makeAudio(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "hold-old-lock" {
            let fd = open(args[2], O_CREAT | O_RDWR, mode_t(0o600))
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { throw Failure.message("old lock") }
            _ = ftruncate(fd, 0) // An old process has no cooperative job ID.
            try Data().write(to: URL(fileURLWithPath: args[3]))
            sleep(20)
            _ = flock(fd, LOCK_UN)
            close(fd)
            return
        }
        if args.count > 1, args[1] == "request-stop" {
            guard try TranscriptionCancellationRequest.check(in: URL(fileURLWithPath: args[2]), requestStop: true) else {
                throw Failure.message("no running job in other process")
            }
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-cancel-" + UUID().uuidString)
        let data = root.appendingPathComponent("data")
        let source = root.appendingPathComponent("source.wav")
        let sentinel = root.appendingPathComponent("worker-started")
        let fakeModel = root.appendingPathComponent("model.bin")
        let fakeWhisper = root.appendingPathComponent("whisper")
        try fm.createDirectory(at: data.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try makeAudio(at: source)
        try Data("model".utf8).write(to: fakeModel)
        let script = "#!/bin/sh\nprintf started > '" + sentinel.path.replacingOccurrences(of: "'", with: "'\\''") + "'\nexec /usr/bin/python3 -c 'import time; time.sleep(120)'\n"
        try Data(script.utf8).write(to: fakeWhisper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeWhisper.path)
        UserDefaults.standard.register(defaults: ["whisperExecutablePath": fakeWhisper.path, "whisperModelPath": fakeModel.path])

        var checks = 0
        do {
            try AudioConverter.convertToWAV(source: source, destination: root.appendingPathComponent("partial.wav")) {
                checks += 1
                if checks >= 3 { throw TranscriptionCancelled() }
            }
            throw Failure.message("conversion did not cancel")
        } catch is TranscriptionCancelled { }
        try check(checks >= 3, "conversion callback not checked during work")

        let service = TranscriptionService()
        let output = TranscriptDocumentStore.preferredURL(recordingID: "one", sourceFileName: "source.wav", directory: data)
        var first: Result<URL, Error>?
        service.transcribe(audioURL: source, outputURL: output, recordingID: "one", sourceFileName: "source.wav") { first = $0 }
        guard await waitFor({ fm.fileExists(atPath: sentinel.path) || first != nil }), fm.fileExists(atPath: sentinel.path) else {
            throw Failure.message("fake Whisper did not start: \(String(describing: first))")
        }
        let started = Date()
        service.cancel()
        guard await waitFor({ first != nil }, timeout: 3) else { throw Failure.message("local cancellation did not stop child promptly") }
        try check(Date().timeIntervalSince(started) < 3, "local cancellation too slow")
        if case .failure(let error)? = first { try check(error is TranscriptionCancelled, "unexpected cancellation error") }
        else { throw Failure.message("local cancellation must fail cleanly") }
        try check(!fm.fileExists(atPath: output.path), "cancelled job wrote a transcript")

        try fm.removeItem(at: sentinel)
        var second: Result<URL, Error>?
        service.transcribe(audioURL: source, outputURL: output, recordingID: "one", sourceFileName: "source.wav") { second = $0 }
        guard await waitFor({ fm.fileExists(atPath: sentinel.path) || second != nil }), fm.fileExists(atPath: sentinel.path) else {
            throw Failure.message("second fake Whisper did not start")
        }
        // A separate process uses the same cooperative channel as the CLI.
        let requester = Process()
        requester.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        requester.arguments = ["request-stop", data.path]
        try requester.run()
        requester.waitUntilExit()
        try check(requester.terminationStatus == 0, "cooperative request did not find running job")
        guard await waitFor({ second != nil }, timeout: 3) else { throw Failure.message("cooperative stop did not terminate child") }
        if case .failure(let error)? = second { try check(error is TranscriptionCancelled, "unexpected cooperative error") }
        else { throw Failure.message("cooperative stop must not succeed") }
        try check(!fm.fileExists(atPath: output.path), "cooperative stop wrote a transcript")
        let stillLocked = try TranscriptionCancellationRequest.check(in: data, requestStop: false)
        try check(!stillLocked, "lock remained held")

        let lockPath = data.appendingPathComponent("transcripts/.memobridge-transcription.lock")
        let locked = root.appendingPathComponent("locked")
        let old = Process()
        old.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        old.arguments = ["hold-old-lock", lockPath.path, locked.path]
        try old.run()
        defer { if old.isRunning { old.terminate(); old.waitUntilExit() } }
        guard await waitFor({ fm.fileExists(atPath: locked.path) }) else { throw Failure.message("old process did not hold lock") }
        let recordings = root.appendingPathComponent("recordings")
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        let store = MemoStore(recordingsDirectories: [recordings], dataDirectoryOverride: data)
        do {
            try await store.stopTranscription()
            throw Failure.message("noncooperative process should not be stopped or allow switching")
        } catch let failure as HiddenRecordingsError {
            try check(failure.localizedDescription.contains("did not stop"), "missing safe timeout message")
        }
        try check(old.isRunning, "noncooperative unrelated process was signalled")
        print("Transcription cancellation: converter, live child, cooperative request, no partial JSON and noncooperative timeout passed")
    }
}
