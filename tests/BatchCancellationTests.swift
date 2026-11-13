import AVFoundation
import Foundation
import SQLite3

private enum BatchTestError: Error { case failure(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw BatchTestError.failure(message) }
}

@main
struct BatchCancellationTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-batch-stop-" + UUID().uuidString)
        let recordings = root.appendingPathComponent("recordings")
        let data = root.appendingPathComponent("data")
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        samples.frameLength = 32_000
        samples.floatChannelData![0].initialize(repeating: 0, count: Int(samples.frameLength))
        let temporaryAudio = root.appendingPathComponent("audio.wav")
        do {
            let file = try AVAudioFile(forWriting: temporaryAudio, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: samples)
        }
        // The reader filters Voice Memo extensions; AVFoundation detects the
        // actual PCM format from the file header in this isolated fixture.
        let firstAudio = recordings.appendingPathComponent("first.m4a")
        try fm.copyItem(at: temporaryAudio, to: firstAudio)
        let secondAudio = recordings.appendingPathComponent("second.m4a")
        try fm.copyItem(at: firstAudio, to: secondAudio)
        for url in [firstAudio, secondAudio] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(recordings.appendingPathComponent("CloudRecordings.db").path, &handle) == SQLITE_OK, let db = handle else {
            throw BatchTestError.failure("could not create test database")
        }
        let sql = "CREATE TABLE ZCLOUDRECORDING (ZUNIQUEID TEXT, ZPATH TEXT, ZDATE REAL, ZDURATION REAL, ZEVICTIONDATE REAL); INSERT INTO ZCLOUDRECORDING VALUES ('one','first.m4a',2,2,NULL); INSERT INTO ZCLOUDRECORDING VALUES ('two','second.m4a',1,2,NULL);"
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        try require(result == SQLITE_OK, "could not create test recordings")
        let sentinel = root.appendingPathComponent("started")
        let fakeWhisper = root.appendingPathComponent("whisper")
        let model = root.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let quoted = sentinel.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf 'start\\n' >> '" + quoted + "'\nexec /usr/bin/python3 -c 'import time; time.sleep(120)'\n"
        try Data(script.utf8).write(to: fakeWhisper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeWhisper.path)
        UserDefaults.standard.register(defaults: ["whisperExecutablePath": fakeWhisper.path, "whisperModelPath": model.path])
        let store = MemoStore(recordingsDirectories: [recordings], dataDirectoryOverride: data)
        try require(store.memos.filter { $0.state == .pending }.count == 2, "both recordings should be pending")
        let batch = Task { await BatchProcessor.run(store: store) }
        for _ in 0..<200 {
            if fm.fileExists(atPath: sentinel.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard fm.fileExists(atPath: sentinel.path) else { throw BatchTestError.failure("the first transcription did not start") }
        try await store.stopTranscription()
        let batchResult = await batch.value
        try require(batchResult != 0, "cancelled batch must exit nonzero")
        let starts = try String(contentsOf: sentinel, encoding: .utf8).split(separator: "\n")
        try require(starts.count == 1, "batch started a second recording after cancellation")
        try require(store.wasTranscriptionCancelled, "batch cancellation state was not recorded")
        try require(store.memos.allSatisfy { $0.transcriptURL == nil && $0.state == .pending }, "cancelled batch should leave both recordings pending")
        print("Batch cancellation: active job stopped, no transcript saved, next recording not started")
    }
}
