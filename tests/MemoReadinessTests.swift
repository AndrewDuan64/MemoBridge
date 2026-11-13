import Darwin
import Foundation
import SQLite3

private enum TestFailure: Error { case failed(String) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

@main
struct MemoReadinessTests {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "lock-worker" {
            let fd = open(arguments[2], O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw TestFailure.failed("worker could not acquire transcription lock")
            }
            defer { flock(fd, LOCK_UN); close(fd) }
            FileHandle.standardOutput.write(Data([1]))
            _ = try FileHandle.standardInput.read(upToCount: 1)
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-readiness-" + UUID().uuidString)
        let source = root.appendingPathComponent("Recordings")
        let data = root.appendingPathComponent("data")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func makeAudio(_ name: String, age: TimeInterval) throws {
            let url = source.appendingPathComponent(name)
            try Data("test audio".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try makeAudio("ready.m4a", age: 120)
        let dbURL = source.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { throw TestFailure.failed("open test database") }
        func sql(_ value: String) throws {
            guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else {
                throw TestFailure.failed("write test database")
            }
        }
        try sql("CREATE TABLE ZCLOUDRECORDING (ZUNIQUEID TEXT, ZPATH TEXT, ZEVICTIONDATE REAL, ZDATE REAL, ZDURATION REAL)")
        let now = Date().timeIntervalSinceReferenceDate
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('ready','ready.m4a',NULL,\(now - 3600),NULL)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('recent','recent.m4a',NULL,\(now),NULL)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('oldmissing','oldmissing.m4a',NULL,\(now - 3600),NULL)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('newmissing','newmissing.m4a',NULL,\(now - 598.8),NULL)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('newappears','newappears.m4a',NULL,\(now - 598.8),NULL)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('longmissing','longmissing.m4a',NULL,\(now - 3600),3600)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('longold','longold.m4a',NULL,\(now - 4201),3600)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('invalidduration','invalidduration.m4a',NULL,\(now - 3600),-1)")
        try sql("INSERT INTO ZCLOUDRECORDING VALUES ('futureend','futureend.m4a',NULL,\(now - 3600),7200)")
        sqlite3_close(db)
        try makeAudio("recent.m4a", age: 59.2)

        let store = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        func state(_ id: String) -> MemoState? { store.memos.first { $0.id == id }?.state }
        try check(state("ready") == .pending, "old stable audio should be ready")
        try check(state("recent") == .preparing, "recently modified audio should wait")
        try check(state("oldmissing") == .unavailable, "old missing audio should not poll indefinitely")
        try check(state("newmissing") == .preparing, "recent missing audio should be retried")
        try check(state("newappears") == .preparing, "recent audio may arrive after metadata")
        try check(state("longmissing") == .preparing, "recently completed long recording should be retried")
        try check(state("longold") == .unavailable, "old long recording should not poll indefinitely")
        try check(state("invalidduration") == .unavailable, "invalid duration should fall back to start time")
        try check(state("futureend") == .unavailable, "implausible future end should fall back to start time")
        store.errorMessage = "转写失败的提示"

        // Move the modification time forward while waiting. The original timer
        // must recheck and defer, instead of treating an actively updated file as ready.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-59)],
                             ofItemAtPath: source.appendingPathComponent("recent.m4a").path)
        try makeAudio("newappears.m4a", age: 120)
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        try check(state("recent") == .preparing, "changed audio must be deferred again")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try check(state("recent") == .pending, "stable audio should become ready automatically")
        try check(state("newappears") == .pending, "newly available audio should become ready automatically")
        try check(state("newmissing") == .unavailable, "retry window should end for missing audio")
        try check(store.errorMessage == "转写失败的提示", "automatic refresh must preserve existing errors")
        store.refresh()
        try check(store.errorMessage == nil, "manual refresh should retain its normal error-clearing behavior")

        // Persisted failures survive a process restart; an interrupted in-flight
        // transcription is eligible for retry rather than stuck as running.
        let failedMetadata = MemoIndexMetadata(id: "ready", sourceTitle: "Ready", sourcePath: "ready.m4a",
                                               date: nil, duration: nil, transcriptionState: MemoState.failed.rawValue)
        try MemoIndex.syncMetadata([failedMetadata], in: data)
        let afterFailure = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        try check(afterFailure.memos.first(where: { $0.id == "ready" })?.state == .failed,
                  "failed transcription status must persist after restart")
        let interruptedMetadata = MemoIndexMetadata(id: "ready", sourceTitle: "Ready", sourcePath: "ready.m4a",
                                                    date: nil, duration: nil, transcriptionState: MemoState.transcribing.rawValue)
        try MemoIndex.syncMetadata([interruptedMetadata], in: data)
        let afterInterruption = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        try check(afterInterruption.memos.first(where: { $0.id == "ready" })?.state == .pending,
                  "interrupted transcription should return to pending on restart")
        let recovered = try MemoIndex.transcriptionStates(in: data)
        try check(recovered["ready"] == MemoState.pending.rawValue,
                  "recovered pending status must be saved to the index")

        // Another app or CLI process can be actively transcribing: its index
        // state must remain active as long as it holds the shared lock.
        let transcriptFolder = data.appendingPathComponent("transcripts", isDirectory: true)
        try fm.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
        let lockPath = transcriptFolder.appendingPathComponent(".memobridge-transcription.lock").path
        let worker = Process()
        let workerInput = Pipe()
        let workerOutput = Pipe()
        worker.executableURL = URL(fileURLWithPath: arguments[0])
        worker.arguments = ["lock-worker", lockPath]
        worker.standardInput = workerInput
        worker.standardOutput = workerOutput
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer {
            try? workerInput.fileHandleForWriting.close()
            if worker.isRunning { worker.terminate() }
        }
        guard try workerOutput.fileHandleForReading.read(upToCount: 1) == Data([1]) else {
            throw TestFailure.failed("lock worker failed to start")
        }
        try MemoIndex.syncMetadata([interruptedMetadata], in: data)
        let whileLocked = MemoStore(recordingsDirectories: [source], dataDirectoryOverride: data)
        try check(whileLocked.memos.first(where: { $0.id == "ready" })?.state == .transcribing,
                  "other process holding the lock must remain transcribing")
        let activeStates = try MemoIndex.transcriptionStates(in: data)
        try check(activeStates["ready"] == MemoState.transcribing.rawValue,
                  "active status must not be overwritten while lock is held")
        try workerInput.fileHandleForWriting.write(contentsOf: Data([1]))
        worker.waitUntilExit()
        try check(worker.terminationStatus == 0, "lock worker should release normally")
        whileLocked.refresh()
        try check(whileLocked.memos.first(where: { $0.id == "ready" })?.state == .pending,
                  "once lock is released, interrupted work returns to pending")
        let releasedStates = try MemoIndex.transcriptionStates(in: data)
        try check(releasedStates["ready"] == MemoState.pending.rawValue,
                  "recovered status must be persisted after lock release")
        print("Memo readiness: stable, changing, missing, retries, cross-process activity and failure/recovery passed")
    }
}
