import Darwin
import Foundation
import SQLite3

private enum TestFailure: Error { case failed(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

@main
struct HiddenRecordingsTests {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "worker" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            for index in 0..<20 {
                let id = "\(args[3])-\(index)"
                try HiddenRecordings.hide(.init(id: id, title: id, date: nil), in: directory)
            }
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-hidden-" + UUID().uuidString)
        let source = root.appendingPathComponent("Recordings", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let audio = source.appendingPathComponent("one.m4a")
        let audioData = Data("original audio".utf8)
        try audioData.write(to: audio)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: audio.path)
        let tags = data.appendingPathComponent("tags.json")
        let tagsData = Data(#"{"one":["Test"]}"#.utf8)
        try tagsData.write(to: tags)

        var db: OpaquePointer?
        guard sqlite3_open(source.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK,
              let db else { throw TestFailure.failed("cannot create test database") }
        defer { sqlite3_close(db) }
        func sql(_ query: String) throws {
            guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw TestFailure.failed("test database statement failed") }
        }
        try sql("CREATE TABLE ZCLOUDRECORDING (ZUNIQUEID TEXT, ZPATH TEXT, ZEVICTIONDATE REAL, ZDATE REAL, ZENCRYPTEDTITLE TEXT)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('one', 'one.m4a', NULL, 700000000, 'Original title')")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('two', NULL, NULL, 600000000, 'Second')")

        let store = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        guard let one = store.memos.first(where: { $0.id == "one" }) else { throw TestFailure.failed("original missing") }
        let transcript = store.transcriptURL(for: one)
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = TranscriptDocument(recordingID: "one", sourceFileName: "one.m4a", text: "my transcript", sourceSignature: nil)
        try TranscriptDocumentStore.writeNew(document: document, to: transcript)
        let transcriptData = try Data(contentsOf: transcript)
        store.refresh()
        guard let selected = store.memos.first(where: { $0.id == "one" }) else { throw TestFailure.failed("original missing after refresh") }
        try require(store.hideMemo(selected), "hide should succeed")
        try require(!store.memos.contains { $0.id == "one" }, "hidden recording must disappear")
        try require(store.hiddenMemos.first(where: { $0.id == "one" })?.isAvailable == true, "hidden source should still be present")
        let transcriptAfterHide = try Data(contentsOf: transcript)
        let migratedTags = try MemoIndex.tags(in: data)
        let backedUpTags = try Data(contentsOf: data.appendingPathComponent(".memobridge-legacy/tags.json"))
        let audioAfterHide = try Data(contentsOf: audio)
        try require(transcriptAfterHide == transcriptData, "transcript must remain intact")
        try require(migratedTags["one"] == ["Test"] && backedUpTags == tagsData, "tags and the original backup must remain intact")
        try require(audioAfterHide == audioData, "Apple audio must remain intact")

        // An already queued item must recheck hidden IDs after it obtains the lock.
        // This is checked before looking for a Whisper engine or starting a process.
        let service = TranscriptionService()
        let staleOutput = transcript.deletingLastPathComponent().appendingPathComponent("stale.txt")
        var staleResult: Result<URL, Error>?
        service.transcribe(audioURL: audio, outputURL: staleOutput, recordingID: "one", sourceFileName: "one.m4a") { staleResult = $0 }
        let deadline = Date().addingTimeInterval(5)
        while staleResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard case .failure(let staleError) = staleResult else { throw TestFailure.failed("stale queued item must fail") }
        try require(staleError.localizedDescription.contains("removed from MemoBridge"), "stale item must fail due to the tombstone")
        try require(!fm.fileExists(atPath: staleOutput.path), "stale item must not create a transcript")

        // Restart / CLI-like instance re-reads stable IDs, even after a source rename.
        try sql("UPDATE ZCLOUDRECORDING SET ZENCRYPTEDTITLE = 'Changed in Voice Memos' WHERE ZUNIQUEID = 'one'")
        let restarted = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        try require(!restarted.memos.contains { $0.id == "one" }, "hidden ID must persist across instances and rename")
        try require(restarted.hiddenMemos.first(where: { $0.id == "one" })?.title == "Changed in Voice Memos", "current Apple title should be shown")

        try sql("DELETE FROM ZCLOUDRECORDING WHERE ZUNIQUEID = 'one'")
        restarted.refresh()
        try require(restarted.hiddenMemos.first(where: { $0.id == "one" })?.isAvailable == false, "missing original should remain restorable")
        try require(restarted.restoreMemo(id: "one"), "missing original's mapping should be restorable")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('one', 'one.m4a', NULL, 700000000, 'Restored')")
        restarted.refresh()
        try require(restarted.memos.contains { $0.id == "one" }, "restored ID should reappear when source returns")

        // Lock shared with a separate transcription prevents hiding in-flight work.
        let lockPath = transcript.deletingLastPathComponent().appendingPathComponent(".memobridge-transcription.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw TestFailure.failed("cannot create test lock") }
        guard let restored = restarted.memos.first(where: { $0.id == "one" }) else { throw TestFailure.failed("restored missing") }
        try require(!restarted.hideMemo(restored), "hide must fail while transcription is locked")
        flock(fd, LOCK_UN); close(fd)
        let hiddenAfterLock = try HiddenRecordings.contains("one", in: data)
        try require(!hiddenAfterLock, "failed hide must not create a tombstone")

        // Corrupted user state fails closed, preserving file contents and blocking processing.
        let brokenData = root.appendingPathComponent("broken-data", isDirectory: true)
        try fm.createDirectory(at: brokenData, withIntermediateDirectories: true)
        let hiddenFile = brokenData.appendingPathComponent("hidden-recordings.json")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: hiddenFile)
        let broken = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: brokenData)
        try require(broken.memos.isEmpty && broken.errorMessage != nil, "corrupt hidden file must block scanning")
        let corruptAfterRead = try Data(contentsOf: hiddenFile)
        try require(corruptAfterRead == corrupt, "corrupt hidden file must not be overwritten")

        // Concurrent writers serialize read-modify-write, preserving both sets of tombstones.
        let concurrent = root.appendingPathComponent("concurrent", isDirectory: true)
        try fm.createDirectory(at: concurrent, withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: args[0])
        let workers = ["A", "B"].map { name -> Process in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["worker", concurrent.path, name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        for worker in workers { try worker.run() }
        for worker in workers { worker.waitUntilExit() }
        try require(workers.allSatisfy { $0.terminationStatus == 0 }, "concurrent writers should complete")
        let concurrentRecords = try HiddenRecordings.load(from: concurrent)
        try require(concurrentRecords.count == 40, "concurrent writes must not lose tombstones")
        print("Hidden recordings: persistence, restore, safe concurrency, and fail-closed checks passed")
    }
}
