import Foundation
import SQLite3

private struct Failure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}

@main
struct MemoIndexTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-index-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try encoder.encode(["one": "Renamed"]).write(to: root.appendingPathComponent("memo-names.json"))
        try encoder.encode(["one": ["Work"], "two": ["Personal"]]).write(to: root.appendingPathComponent("tags.json"))
        try encoder.encode(["two": HiddenRecordingSnapshot(id: "two", title: "Hidden", date: date)]).write(to: root.appendingPathComponent("hidden-recordings.json"))
        try check(try MemoIndex.names(in: root)["one"] == "Renamed", "name migration")
        try check(try MemoIndex.tags(in: root)["two"] == ["Personal"], "tag migration")
        try check(try MemoIndex.hidden(in: root)["two"]?.date == date, "hidden migration")
        for name in ["memo-names.json", "tags.json", "hidden-recordings.json"] {
            try check(fm.fileExists(atPath: root.appendingPathComponent(".memobridge-legacy/" + name).path), "legacy backup missing")
            try check(!fm.fileExists(atPath: root.appendingPathComponent(name).path), "migrated legacy file still active")
        }
        try MemoIndex.syncMetadata([MemoIndexMetadata(id: "one", sourceTitle: "Original", sourcePath: "one.m4a", date: date, duration: 12, transcriptionState: "complete")], in: root)
        try check(try MemoIndex.transcriptionStates(in: root)["one"] == "complete", "sync should persist transcription status")
        try MemoIndex.setTranscriptionState(id: "one", state: "failed", in: root)
        try check(try MemoIndex.transcriptionStates(in: root)["one"] == "failed", "transcription failure should persist")
        try MemoIndex.setTranscriptionState(id: "one", state: "transcribing", in: root)
        try check(try MemoIndex.transcriptionStates(in: root)["one"] == "transcribing", "retry should update status")
        try MemoIndex.setName(id: "one", name: "Again", in: root)
        try MemoIndex.changeTag("Work", memoID: "two", add: true, in: root)
        try check(try MemoIndex.names(in: root)["one"] == "Again", "name update")
        try check(try MemoIndex.hidden(in: root)["two"] != nil, "hidden survives other updates")
        try check(try MemoIndex.tags(in: root)["two"] == ["Personal", "Work"], "tag update")
        let key = "notebookUpload.test." + UUID().uuidString
        try check(try MemoIndex.claimUpload(key: key, recordingID: "one", in: root) == nil, "first upload claimed")
        try check(try MemoIndex.claimUpload(key: key, recordingID: "one", in: root) == "unknown", "second upload blocked")
        try MemoIndex.setUploadState("active|source", key: key, recordingID: "one", in: root)
        try check(try MemoIndex.uploadState(key: key, recordingID: "one", in: root) == "active|source", "upload status stored")
        try MemoIndex.setUploadState(nil, key: key, recordingID: "one", in: root)
        try check(try MemoIndex.uploadState(key: key, recordingID: "one", in: root) == nil, "cleared upload remains cleared")
        // Independent SQLite connections must not lose concurrent tag updates
        // or both believe they own the same network upload.
        let sync = NSLock()
        var failures: [String] = []
        let concurrentKey = "notebookUpload.concurrent." + UUID().uuidString
        var uploadOwners = 0
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                try MemoIndex.changeTag("parallel-\(index)", memoID: "one", add: true, in: root)
                let prior = try MemoIndex.claimUpload(key: concurrentKey, recordingID: "one", in: root)
                if prior == nil { sync.lock(); uploadOwners += 1; sync.unlock() }
            } catch {
                sync.lock(); failures.append(error.localizedDescription); sync.unlock()
            }
        }
        try check(failures.isEmpty, "concurrent operations should succeed")
        try check(try MemoIndex.tags(in: root)["one"]?.count == 17, "concurrent tag updates lost")
        try check(uploadOwners == 1, "exactly one upload should be claimed")
        try MemoIndex.restore(id: "two", in: root)
        try check(try MemoIndex.hidden(in: root)["two"] == nil, "restore")
        try check(try MemoIndex.tags(in: root)["two"] == ["Personal", "Work"], "restore retains tags")

        let sourceRoot = root.appendingPathComponent("Apple Recordings")
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceLink = root.appendingPathComponent("source link")
        try fm.createSymbolicLink(at: sourceLink, withDestinationURL: sourceRoot)
        for forbidden in [sourceRoot, sourceRoot.appendingPathComponent("child"), sourceLink.appendingPathComponent("child")] {
            do {
                try MemoIndex.validateDataDirectory(forbidden, recordingRoots: [sourceRoot])
                throw Failure(message: "Voice Memos directory must be rejected")
            } catch let error as Failure { throw error }
            catch { }
        }
        try check(!fm.fileExists(atPath: sourceRoot.appendingPathComponent("child").path), "validation must not create directories")

        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        let bad = broken.appendingPathComponent("hidden-recordings.json")
        let original = Data("not JSON".utf8)
        try original.write(to: bad)
        do {
            _ = try MemoIndex.names(in: broken)
            throw Failure(message: "corrupt legacy data should block migration")
        } catch let error as Failure { throw error }
        catch { }
        try check(try Data(contentsOf: bad) == original, "corrupt original must survive")
        try check(!fm.fileExists(atPath: broken.appendingPathComponent(".memobridge-legacy/hidden-recordings.json").path), "corrupt original must not be archived")

        print("Memo index: legacy migration, backups, tags/names/hidden, metadata, upload deduplication and fail-closed corruption passed")
    }
}
