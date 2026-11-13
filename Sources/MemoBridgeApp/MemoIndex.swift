import CryptoKit
import Darwin
import Foundation
import SQLite3

struct MemoIndexMetadata {
    let id: String
    let sourceTitle: String
    let sourcePath: String?
    let date: Date?
    let duration: Double?
    let transcriptionState: String
}

private struct MemoIndexError: LocalizedError {
    let detail: String
    var errorDescription: String? { "Cannot access the MemoBridge index. \(detail)" }
}

/// Per-data-folder SQLite index. Every mutation is a transaction; legacy files
/// are imported once and preserved in a backup after successful migration.
enum MemoIndex {
    private static let databaseName = "memo-index.sqlite3"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func run(_ db: OpaquePointer, _ sql: String, _ bind: (OpaquePointer) throws -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoIndexError(detail: "Unable to prepare a database operation.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MemoIndexError(detail: "A database operation failed: \(String(cString: sqlite3_errmsg(db))).")
        }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ bind: (OpaquePointer) throws -> Void = { _ in }, _ row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoIndexError(detail: "Unable to read the database.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw MemoIndexError(detail: "Unable to read database records: \(String(cString: sqlite3_errmsg(db))).")
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func bindText(_ value: String?, _ statement: OpaquePointer, _ index: Int32) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
        else { sqlite3_bind_null(statement, index) }
    }
    private static func bindDouble(_ value: Double?, _ statement: OpaquePointer, _ index: Int32) {
        if let value, value.isFinite { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private static func legacyData(_ name: String, in directory: URL) throws -> Data? {
        let url = directory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw MemoIndexError(detail: "Cannot inspect legacy file \(name).")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw MemoIndexError(detail: "Legacy file \(name) is not a regular file; it was not changed.")
        }
        do { return try Data(contentsOf: url) }
        catch { throw MemoIndexError(detail: "Cannot read legacy file \(name); it was not changed.") }
    }

    private static func resolvedPath(_ url: URL) throws -> String {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while true {
            var info = stat()
            if lstat(ancestor.path, &info) == 0 { break }
            guard errno == ENOENT, ancestor.path != "/" else {
                throw MemoIndexError(detail: "Cannot inspect the data folder path.")
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    /// Never create an index inside Apple's Voice Memos folders, even when a
    /// different subsystem opens it before MemoStore has validated the folder.
    static func validateDataDirectory(_ directory: URL, recordingRoots: [URL]? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = recordingRoots ?? [
            home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        ]
        let dataPath = try resolvedPath(directory)
        for root in roots {
            let sourcePath = try resolvedPath(root)
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            guard dataPath != sourcePath && !dataPath.hasPrefix(prefix) else {
                throw MemoIndexError(detail: "The data folder cannot be inside Voice Memos recordings.")
            }
        }
    }

    private static func withDatabase<T>(in directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        try validateDataDirectory(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(databaseName).path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw MemoIndexError(detail: "Cannot inspect the index file.") }
            // Reserve a new private file without following symlinks or replacing
            // anything. An interrupted initialization is safe to retry.
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            if fd >= 0 { close(fd) }
            else if errno != EEXIST { throw MemoIndexError(detail: "Cannot create the index file.") }
            guard lstat(path, &info) == 0 else { throw MemoIndexError(detail: "Cannot inspect the index file.") }
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw MemoIndexError(detail: "The index is not a regular file; it was not changed.")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw MemoIndexError(detail: "Cannot open the index file.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try run(db, "BEGIN IMMEDIATE")
        do {
            var existingTables = Set<String>()
            try query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", { _ in }) { row in
                if let name = text(row, 0) { existingTables.insert(name) }
            }
            let isNewIndex = existingTables.isEmpty
            guard isNewIndex || existingTables == Set(["metadata", "recordings", "uploads"]) else {
                throw MemoIndexError(detail: "The index file contains an unknown database; it was not changed.")
            }
            try run(db, "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try run(db, """
                CREATE TABLE IF NOT EXISTS recordings (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_name TEXT, hidden INTEGER NOT NULL DEFAULT 0,
                    hidden_title TEXT, hidden_date REAL,
                    tags TEXT NOT NULL DEFAULT '[]',
                    source_title TEXT, source_path TEXT, recorded_at REAL, duration REAL,
                    transcription_state TEXT
                )
                """)
            try run(db, "CREATE TABLE IF NOT EXISTS uploads (key TEXT PRIMARY KEY NOT NULL, recording_id TEXT NOT NULL, state TEXT)")
            var migration: String?
            try query(db, "SELECT value FROM metadata WHERE key='schema_version'", { _ in }) { migration = text($0, 0) }
            if let migration {
                guard migration == "1" else { throw MemoIndexError(detail: "Unsupported index version; no data was changed.") }
            } else {
                guard isNewIndex else { throw MemoIndexError(detail: "The index version is missing; it was not changed.") }
                try importLegacy(db, in: directory)
                try run(db, "INSERT INTO metadata (key,value) VALUES ('schema_version','1')")
            }
            let result = try body(db)
            try run(db, "COMMIT")
            archiveLegacyIfUnchanged(db, in: directory)
            return result
        } catch {
            try? run(db, "ROLLBACK")
            throw error
        }
    }

    private static func importLegacy(_ db: OpaquePointer, in directory: URL) throws {
        let decoder = JSONDecoder()
        do {
            if let data = try legacyData("memo-names.json", in: directory) {
                try recordLegacyDigest(data, name: "memo-names.json", db: db)
                let names = try decoder.decode([String: String].self, from: data)
                guard names.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else { throw MemoIndexError(detail: "Invalid legacy names.") }
                for (id, name) in names {
                    try run(db, "INSERT INTO recordings (id,local_name) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET local_name=excluded.local_name") {
                        bindText(id, $0, 1); bindText(name, $0, 2)
                    }
                }
            }
            if let data = try legacyData("tags.json", in: directory) {
                try recordLegacyDigest(data, name: "tags.json", db: db)
                let tags = try decoder.decode([String: [String]].self, from: data)
                guard tags.allSatisfy({ !$0.key.isEmpty && $0.value.allSatisfy({ !$0.isEmpty }) }) else { throw MemoIndexError(detail: "Invalid legacy tags.") }
                for (id, values) in tags {
                    let encoded = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
                    try run(db, "INSERT INTO recordings (id,tags) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET tags=excluded.tags") {
                        bindText(id, $0, 1); bindText(encoded, $0, 2)
                    }
                }
            }
            if let data = try legacyData("hidden-recordings.json", in: directory) {
                try recordLegacyDigest(data, name: "hidden-recordings.json", db: db)
                let hidden = try decoder.decode([String: HiddenRecordingSnapshot].self, from: data)
                guard hidden.allSatisfy({ !$0.key.isEmpty && $0.key == $0.value.id }) else { throw MemoIndexError(detail: "Invalid legacy hidden recordings.") }
                for (id, snapshot) in hidden {
                    try run(db, "INSERT INTO recordings (id,hidden,hidden_title,hidden_date) VALUES (?,1,?,?) ON CONFLICT(id) DO UPDATE SET hidden=1,hidden_title=excluded.hidden_title,hidden_date=excluded.hidden_date") {
                        bindText(id, $0, 1); bindText(snapshot.title, $0, 2); bindDouble(snapshot.date?.timeIntervalSince1970, $0, 3)
                    }
                }
            }
        } catch {
            throw MemoIndexError(detail: "Could not migrate the existing names, tags, or hidden recordings. Original files were not changed. \(error.localizedDescription)")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func recordLegacyDigest(_ data: Data, name: String, db: OpaquePointer) throws {
        try run(db, "INSERT INTO metadata(key,value) VALUES (?,?)") {
            bindText("legacy-sha:" + name, $0, 1); bindText(digest(data), $0, 2)
        }
    }

    /// Only move originals after the DB commit and only if they still match the
    /// imported bytes. A pre-existing backup or changed file is never overwritten.
    private static func archiveLegacyIfUnchanged(_ db: OpaquePointer, in directory: URL) {
        var digests: [(String, String)] = []
        do {
            try query(db, "SELECT key,value FROM metadata WHERE key LIKE 'legacy-sha:%'", { _ in }) { row in
                if let key = text(row, 0), let value = text(row, 1) {
                    digests.append((String(key.dropFirst("legacy-sha:".count)), value))
                }
            }
            guard !digests.isEmpty else { return }
            let backup = directory.appendingPathComponent(".memobridge-legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(backup.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return }
            for (name, expected) in digests {
                guard ["memo-names.json", "tags.json", "hidden-recordings.json"].contains(name),
                      let bytes = try legacyData(name, in: directory), digest(bytes) == expected else { continue }
                let destination = backup.appendingPathComponent(name)
                var destinationInfo = stat()
                guard lstat(destination.path, &destinationInfo) != 0 && errno == ENOENT else { continue }
                try? FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: destination)
            }
        } catch {
            // The index is already committed. Leave every unarchived file in place.
        }
    }

    static func names(in directory: URL) throws -> [String: String] {
        try withDatabase(in: directory) { db in
            var result: [String: String] = [:]
            try query(db, "SELECT id,local_name FROM recordings WHERE local_name IS NOT NULL", { _ in }) { row in
                guard let id = text(row, 0), let name = text(row, 1), !id.isEmpty, !name.isEmpty else { throw MemoIndexError(detail: "Invalid local name entry.") }
                result[id] = name
            }
            return result
        }
    }

    static func setName(id: String, name: String, in directory: URL) throws {
        guard !id.isEmpty && !name.isEmpty else { throw MemoIndexError(detail: "Invalid name or recording ID.") }
        try withDatabase(in: directory) { db in
            try run(db, "INSERT INTO recordings(id,local_name) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET local_name=excluded.local_name") {
                bindText(id, $0, 1); bindText(name, $0, 2)
            }
        }
    }

    static func transcriptionStates(in directory: URL) throws -> [String: String] {
        try withDatabase(in: directory) { db in
            var states: [String: String] = [:]
            try query(db, "SELECT id,transcription_state FROM recordings WHERE transcription_state IS NOT NULL", { _ in }) { row in
                guard let id = text(row, 0), let state = text(row, 1), !id.isEmpty else {
                    throw MemoIndexError(detail: "Invalid transcription status entry.")
                }
                states[id] = state
            }
            return states
        }
    }

    static func setTranscriptionState(id: String, state: String, in directory: URL) throws {
        guard !id.isEmpty, !state.isEmpty else { throw MemoIndexError(detail: "Invalid transcription status.") }
        try withDatabase(in: directory) { db in
            try run(db, "INSERT INTO recordings(id,transcription_state) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET transcription_state=excluded.transcription_state") {
                bindText(id, $0, 1); bindText(state, $0, 2)
            }
        }
    }

    static func syncMetadata(_ records: [MemoIndexMetadata], in directory: URL) throws {
        try withDatabase(in: directory) { db in
            for record in records {
                guard !record.id.isEmpty else { throw MemoIndexError(detail: "Missing recording ID.") }
                try run(db, """
                    INSERT INTO recordings(id,source_title,source_path,recorded_at,duration,transcription_state) VALUES (?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET source_title=excluded.source_title,source_path=excluded.source_path,
                    recorded_at=excluded.recorded_at,duration=excluded.duration,transcription_state=excluded.transcription_state
                    """) {
                    bindText(record.id, $0, 1); bindText(record.sourceTitle, $0, 2); bindText(record.sourcePath, $0, 3)
                    bindDouble(record.date?.timeIntervalSince1970, $0, 4); bindDouble(record.duration, $0, 5); bindText(record.transcriptionState, $0, 6)
                }
            }
        }
    }

    static func hidden(in directory: URL) throws -> [String: HiddenRecordingSnapshot] {
        try withDatabase(in: directory) { db in
            var result: [String: HiddenRecordingSnapshot] = [:]
            try query(db, "SELECT id,hidden_title,hidden_date FROM recordings WHERE hidden=1", { _ in }) { row in
                guard let id = text(row, 0), !id.isEmpty, let title = text(row, 1) else { throw MemoIndexError(detail: "Invalid hidden recording entry.") }
                let date = sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 2))
                result[id] = HiddenRecordingSnapshot(id: id, title: title, date: date)
            }
            return result
        }
    }

    static func setHidden(_ snapshot: HiddenRecordingSnapshot, in directory: URL) throws {
        guard !snapshot.id.isEmpty else { throw MemoIndexError(detail: "Missing recording ID.") }
        try withDatabase(in: directory) { db in
            try run(db, "INSERT INTO recordings(id,hidden,hidden_title,hidden_date) VALUES (?,1,?,?) ON CONFLICT(id) DO UPDATE SET hidden=1,hidden_title=excluded.hidden_title,hidden_date=excluded.hidden_date") {
                bindText(snapshot.id, $0, 1); bindText(snapshot.title, $0, 2); bindDouble(snapshot.date?.timeIntervalSince1970, $0, 3)
            }
        }
    }

    static func restore(id: String, in directory: URL) throws {
        try withDatabase(in: directory) { db in
            try run(db, "UPDATE recordings SET hidden=0,hidden_title=NULL,hidden_date=NULL WHERE id=? AND hidden=1") { bindText(id, $0, 1) }
            guard sqlite3_changes(db) == 1 else { throw HiddenRecordingsError.message("This recording is no longer in the hidden list.") }
        }
    }

    static func tags(in directory: URL) throws -> [String: [String]] {
        try withDatabase(in: directory) { db in
            var result: [String: [String]] = [:]
            try query(db, "SELECT id,tags FROM recordings", { _ in }) { row in
                guard let id = text(row, 0), let encoded = text(row, 1), let data = encoded.data(using: .utf8) else { throw MemoIndexError(detail: "Invalid tag data.") }
                let values = try JSONDecoder().decode([String].self, from: data)
                if !values.isEmpty { result[id] = values }
            }
            return result
        }
    }

    private static func tagKey(_ value: String) -> String { value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }

    static func changeTag(_ tag: String, memoID: String, add: Bool, in directory: URL) throws {
        guard !memoID.isEmpty else { throw MemoIndexError(detail: "Missing recording ID.") }
        try withDatabase(in: directory) { db in
            var allTags: [String] = []
            var current: [String] = []
            try query(db, "SELECT id,tags FROM recordings", { _ in }) { row in
                guard let id = text(row, 0), let raw = text(row, 1), let data = raw.data(using: .utf8) else { throw MemoIndexError(detail: "Invalid tag data.") }
                let values = try JSONDecoder().decode([String].self, from: data)
                allTags.append(contentsOf: values)
                if id == memoID { current = values }
            }
            let normalized = tagKey(tag)
            if add {
                if !current.contains(where: { tagKey($0) == normalized }) {
                    current.append(allTags.first(where: { tagKey($0) == normalized }) ?? tag)
                }
            } else {
                current.removeAll { tagKey($0) == normalized }
            }
            let encoded = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
            try run(db, "INSERT INTO recordings(id,tags) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET tags=excluded.tags") {
                bindText(memoID, $0, 1); bindText(encoded, $0, 2)
            }
        }
    }

    /// Legacy keys were based on recording ID, notebook and transcript text digest.
    /// A row with NULL state records that this key has already been migrated or cleared.
    static func uploadState(key: String, recordingID: String, in directory: URL) throws -> String? {
        try withDatabase(in: directory) { db in
            var exists = false
            var state: String?
            try query(db, "SELECT state FROM uploads WHERE key=?", { bindText(key, $0, 1) }) { row in
                exists = true; state = text(row, 0)
            }
            if !exists {
                state = UserDefaults.standard.string(forKey: key)
                try run(db, "INSERT INTO uploads(key,recording_id,state) VALUES (?,?,?)") {
                    bindText(key, $0, 1); bindText(recordingID, $0, 2); bindText(state, $0, 3)
                }
            }
            return state
        }
    }

    /// Atomically claim a not-yet-uploaded item before making a network request.
    /// Existing or legacy states are returned so callers can check/recover them.
    static func claimUpload(key: String, recordingID: String, in directory: URL) throws -> String? {
        try withDatabase(in: directory) { db in
            var exists = false
            var previous: String?
            try query(db, "SELECT state FROM uploads WHERE key=?", { bindText(key, $0, 1) }) { row in
                exists = true; previous = text(row, 0)
            }
            if !exists { previous = UserDefaults.standard.string(forKey: key) }
            let next = previous ?? "unknown"
            try run(db, "INSERT INTO uploads(key,recording_id,state) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET recording_id=excluded.recording_id,state=excluded.state") {
                bindText(key, $0, 1); bindText(recordingID, $0, 2); bindText(next, $0, 3)
            }
            return previous
        }
    }

    static func setUploadState(_ state: String?, key: String, recordingID: String, in directory: URL) throws {
        try withDatabase(in: directory) { db in
            try run(db, "INSERT INTO uploads(key,recording_id,state) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET recording_id=excluded.recording_id,state=excluded.state") {
                bindText(key, $0, 1); bindText(recordingID, $0, 2); bindText(state, $0, 3)
            }
        }
    }
}
