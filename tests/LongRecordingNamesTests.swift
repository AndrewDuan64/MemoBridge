import Foundation
import SQLite3

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.failed(message) }
}

@main
struct LongRecordingNamesTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-names-" + UUID().uuidString)
        let recordings = root.appendingPathComponent("Recordings")
        let data = root.appendingPathComponent("data")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        let audio = recordings.appendingPathComponent("test.m4a")
        let audioData = Data("audio".utf8)
        try audioData.write(to: audio)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: audio.path)
        var db: OpaquePointer?
        guard sqlite3_open(recordings.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK, let db else {
            throw TestFailure.failed("open database")
        }
        let sql = "CREATE TABLE ZCLOUDRECORDING (ZUNIQUEID TEXT, ZPATH TEXT, ZEVICTIONDATE REAL); INSERT INTO ZCLOUDRECORDING VALUES ('test','test.m4a',NULL);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure.failed("create test recording") }
        sqlite3_close(db)

        let store = MemoStore(recordingsDirectories: [recordings], dataDirectoryOverride: data)
        guard let original = store.memos.first else { throw TestFailure.failed("missing recording") }
        let oldURL = LocalMemoNames.preferredTranscriptURL(id: original.id, title: nil, directory: data)
        try fm.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldText = Data("transcript".utf8)
        let attrs = try fm.attributesOfItem(atPath: audio.path)
        guard let modified = attrs[.modificationDate] as? Date else { throw TestFailure.failed("source modification date") }
        let signature = TranscriptSourceSignature(size: UInt64(audioData.count), modificationTime: modified.timeIntervalSince1970)
        let oldMetadata = try JSONEncoder().encode(signature)
        try oldText.write(to: oldURL)
        try oldMetadata.write(to: oldURL.appendingPathExtension("source.json"))
        store.refresh()
        guard let memo = store.memos.first, let migratedURL = memo.transcriptURL else {
            throw TestFailure.failed("legacy transcript failed to migrate: \(store.errorMessage ?? "no message")")
        }
        try check(migratedURL.pathExtension == "json", "transcript should migrate to JSON")
        try check(migratedURL.lastPathComponent.hasPrefix("test.m4a--"), "filename should match source audio")
        try check(memo.state == .complete, "source signature must retain completed status")
        let document = try TranscriptDocumentStore.read(url: migratedURL)
        try check(document.text == "transcript" && document.recordingID == "test", "migrated document must preserve content and ID")
        try check(document.sourceSignature == signature, "migrated source signature must be preserved")
        let backupDir = data.appendingPathComponent("legacy-transcripts", isDirectory: true)
        try check(try Data(contentsOf: backupDir.appendingPathComponent(oldURL.lastPathComponent)) == oldText, "legacy transcript backup must be preserved")
        try check(try Data(contentsOf: backupDir.appendingPathComponent(oldURL.appendingPathExtension("source.json").lastPathComponent)) == oldMetadata, "legacy metadata backup must be preserved")
        try check(!fm.fileExists(atPath: oldURL.path), "legacy transcript should no longer be in active folder")
        let longTitle = String(repeating: "长", count: 1000)
        try check(store.rename(memo, to: longTitle), "1000 characters should be accepted")
        try check(store.memos.first?.title == longTitle, "title should be retained")
        let reopened = MemoStore(recordingsDirectories: [recordings], dataDirectoryOverride: data)
        try check(reopened.memos.first?.title == longTitle, "title should persist")
        guard let renamed = reopened.memos.first, let transcript = renamed.transcriptURL else { throw TestFailure.failed("renamed transcript") }
        try check(transcript.resolvingSymlinksInPath() == migratedURL.resolvingSymlinksInPath(), "local display rename must not change source-aligned JSON filename")
        try check(try TranscriptDocumentStore.read(url: transcript).text == "transcript", "transcript must survive rename")
        try check(renamed.state == .complete, "status must survive rename and restart")
        // Apple may rename its backing file. Stable recording IDs must still locate
        // the existing document even though its path reflects the earlier source name.
        let movedAudio = recordings.appendingPathComponent("moved.m4a")
        try fm.moveItem(at: audio, to: movedAudio)
        var reopenedDB: OpaquePointer?
        guard sqlite3_open(recordings.appendingPathComponent("CloudRecordings.db").path, &reopenedDB) == SQLITE_OK,
              let reopenedDB else { throw TestFailure.failed("reopen source database") }
        let updateResult = sqlite3_exec(reopenedDB, "UPDATE ZCLOUDRECORDING SET ZPATH='moved.m4a' WHERE ZUNIQUEID='test'", nil, nil, nil)
        sqlite3_close(reopenedDB)
        guard updateResult == SQLITE_OK else { throw TestFailure.failed("update source filename") }
        reopened.refresh()
        guard let movedMemo = reopened.memos.first, let movedTranscript = movedMemo.transcriptURL else {
            throw TestFailure.failed("transcript not found after source filename change")
        }
        try check(movedMemo.sourceFileName == "moved.m4a", "reader must reflect new source name")
        try check(movedTranscript.resolvingSymlinksInPath() == migratedURL.resolvingSymlinksInPath(), "stable ID should find the original JSON after source rename")
        try check(try TranscriptDocumentStore.read(url: movedTranscript).text == "transcript", "source rename must not lose transcript")
        try check(movedMemo.state == .complete, "source rename without content change must preserve status")
        try check(!reopened.rename(renamed, to: longTitle + "字"), "1001 characters should be rejected")
        try check(reopened.memos.first?.title == longTitle, "rejected title should not change data")

        let emojiTitle = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
        try check(emojiTitle.count == 1000, "emoji should be counted as extended grapheme clusters")
        try check(reopened.rename(renamed, to: emojiTitle), "1000 joined emoji should be accepted")
        let emojiReopened = MemoStore(recordingsDirectories: [recordings], dataDirectoryOverride: data)
        try check(emojiReopened.memos.first?.title == emojiTitle, "joined emoji title should persist")
        try check(!reopened.rename(renamed, to: emojiTitle + "字"), "1001 characters should be rejected")
        try check(reopened.errorMessage?.contains("at most 1000") == true, "length error should identify the limit")
        try check(!reopened.rename(renamed, to: "short\nname"), "line breaks should be rejected")
        try check(reopened.errorMessage?.contains("line breaks") == true, "line break error should identify the cause")
        try check(!reopened.rename(renamed, to: "short\tname"), "control characters should be rejected")
        try check(reopened.errorMessage?.contains("control characters") == true, "control error should identify the cause")
        try check(!reopened.rename(renamed, to: "  "), "empty names should be rejected")
        try check(reopened.errorMessage == "Enter a recording name.", "empty-name error should identify the cause")
        try check(reopened.memos.first?.title == emojiTitle, "invalid names should leave the title untouched")

        // One extended grapheme can contain enough decomposed bytes to exceed the
        // file system component limit even though it counts as one character.
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 200)
        try check(reopened.rename(renamed, to: hugeGrapheme), "large grapheme should not cause filename overflow")
        guard let newTranscript = reopened.memos.first?.transcriptURL else { throw TestFailure.failed("large grapheme transcript") }
        try check(newTranscript.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count <= 240, "transcript component too long")
        try check(newTranscript.resolvingSymlinksInPath() == migratedURL.resolvingSymlinksInPath(), "local title must never change the source-aligned filename")
        try check(try TranscriptDocumentStore.read(url: newTranscript).text == "transcript", "transcript should survive another rename")

        // Conflicting user data must never be overwritten or silently treated as
        // the existing transcript, even when both old and new files are found.
        let conflict = Data("different legacy transcript".utf8)
        try conflict.write(to: oldURL)
        let beforeJSON = try Data(contentsOf: newTranscript)
        reopened.refresh()
        try check(reopened.errorMessage != nil, "conflicting old/new files should be reported")
        try check(try Data(contentsOf: oldURL) == conflict, "conflicting legacy transcript must remain unchanged")
        try check(try Data(contentsOf: newTranscript) == beforeJSON, "existing JSON must remain unchanged")
        print("Recording names: 1000-character persistence, joined emoji, legacy JSON migration, original backup, stable source filenames and conflict safety passed")
    }
}
