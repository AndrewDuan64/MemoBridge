import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import SQLite3

enum MemoState: String, Equatable {
    case unavailable, preparing, pending, transcribing, complete, outdated, failed
}

struct Memo: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date?
    let duration: Double?
    let audioURL: URL?
    let sourceFileName: String
    let transcriptURL: URL?
    let state: MemoState
}

/// Local display names are keyed by the Voice Memos identifier. Apple data is read-only.
enum LocalMemoNames {
    /// Reject line breaks and control codes while allowing Unicode format
    /// characters such as the zero-width joiners used in emoji and scripts.
    static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.newlines.contains(scalar) || scalar.properties.generalCategory == .control
    }

    static func load(from directory: URL) throws -> [String: String] {
        try MemoIndex.names(in: directory)
    }

    static func preferredTranscriptURL(id: String, title: String?, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let name: String
        if let title {
            // macOS file systems limit each component by bytes, often after
            // Unicode decomposition. Reserve room for the ID and .source.json
            // sidecar even when a single visible character has many scalars.
            var prefix = ""
            var byteCount = 0
            for character in title.prefix(32) {
                let safe = character == "/" || character == ":" || character.unicodeScalars.contains(where: isForbiddenControl) ? "_" : String(character)
                let bytes = safe.decomposedStringWithCanonicalMapping.utf8.count
                guard byteCount + bytes <= 120 else { break }
                prefix += safe
                byteCount += bytes
            }
            let cleaned = prefix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            name = "\(cleaned.isEmpty ? "Recording" : cleaned)--\(hash).txt"
        } else {
            name = "memo-\(hash).txt"
        }
        return directory.appendingPathComponent("transcripts", isDirectory: true).appendingPathComponent(name)
    }

    /// Recover a unique previous filename after an interrupted rename.
    static func transcriptURL(id: String, title: String?, directory: URL) throws -> URL {
        let target = preferredTranscriptURL(id: id, title: title, directory: directory)
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return target }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            $0 == "memo-\(hash).txt" || $0.hasSuffix("--\(hash).txt")
        }
        guard names.count <= 1 else {
            throw RecordingError(message: "More than one transcript matches this recording. Resolve the duplicate files in the transcripts folder before continuing.")
        }
        return names.first.map { folder.appendingPathComponent($0) } ?? target
    }
}

private struct SourceSignature: Codable, Equatable {
    let size: UInt64
    let modificationTime: TimeInterval

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modificationTime = modified.timeIntervalSince1970
    }
}

private struct Recording {
    let id: String
    let title: String
    let date: Date?
    let duration: Double?
    let sourceFileName: String
    let sourcePath: String?
    let audioURL: URL?
    let readyAfter: Date?
}

private struct RecordingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Creates one reference to the Voice Memos folder. Never overwrites user data.
enum AudioLinkManager {
    static let linkName = "Voice Memos"

    static func synchronize(in dataDirectory: URL, sourceDirectory: URL) throws {
        let fm = FileManager.default
        let source = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        guard directory.path != source.path && !directory.path.hasPrefix(sourcePrefix) else {
            throw RecordingError(message: "The data folder cannot be inside the Voice Memos recordings folder.")
        }
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw RecordingError(message: "The Voice Memos recordings folder is unavailable.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(linkName)
        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
                  let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
                throw RecordingError(message: "A file or folder named ‘Voice Memos’ already exists in the data folder. It was not changed.")
            }
            let existingURL = URL(fileURLWithPath: existing, relativeTo: directory)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard existingURL == source else {
                throw RecordingError(message: "The ‘Voice Memos’ link already points somewhere else. It was not changed.")
            }
            return
        }
        guard errno == ENOENT else {
            throw RecordingError(message: "Cannot inspect the ‘Voice Memos’ link: \(String(cString: strerror(errno))).")
        }
        // createSymbolicLink fails if a destination appears concurrently; it never replaces it.
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
    }
}

/// The Voice Memos database is an undocumented format: fail closed if its schema changes.
private enum VoiceMemoReader {
    static let defaultDirectories = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings")
    ]

    static func read(from directory: URL) throws -> [Recording] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let dbURL = root.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        let result = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw RecordingError(message: "Cannot read the Voice Memos database. Make sure recordings are synced to this Mac and allow MemoBridge to access Voice Memos in System Settings.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        var columns = Set<String>()
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(ZCLOUDRECORDING)", -1, &schema, nil) == SQLITE_OK else {
            throw RecordingError(message: "Cannot inspect the Voice Memos database.")
        }
        defer { sqlite3_finalize(schema) }
        while sqlite3_step(schema) == SQLITE_ROW {
            if let value = sqlite3_column_text(schema, 1) { columns.insert(String(cString: value)) }
        }
        guard Set(["ZUNIQUEID", "ZPATH", "ZEVICTIONDATE"]).isSubset(of: columns) else {
            throw RecordingError(message: "This Voice Memos database format is not supported.")
        }
        func field(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = "SELECT ZUNIQUEID, ZPATH, \(field("ZDATE")), \(field("ZDURATION")), \(field("ZENCRYPTEDTITLE")), \(field("ZCUSTOMLABELFORSORTING")), \(field("ZCUSTOMLABEL")) FROM ZCLOUDRECORDING WHERE ZEVICTIONDATE IS NULL"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RecordingError(message: "Cannot read the recording list. Check access permissions.")
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                  let value = sqlite3_column_text(statement, column) else { return nil }
            let result = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        var entries: [Recording] = []
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            guard let id = text(0) else {
                resultCode = sqlite3_step(statement)
                continue
            }
            let date = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            let title = text(4) ?? text(5) ?? text(6) ?? date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Untitled Recording"
            var audioURL: URL?
            var readyAfter: Date?
            // Recent metadata can arrive before its audio. Retry for a bounded
            // period; old missing recordings must not create a permanent poll.
            func retryRecentUnavailable() -> Date? {
                let now = Date()
                guard let date, date.timeIntervalSince(now) <= 60 else { return nil }
                // ZDATE is the start of recording. A long recording can have an
                // old start time even though its audio has only just finished
                // syncing, so use a plausible estimated end time when available.
                let anchor: Date
                if let duration, duration.isFinite, duration > 0, duration <= 7 * 24 * 60 * 60 {
                    let estimatedEnd = date.addingTimeInterval(duration)
                    anchor = estimatedEnd.timeIntervalSince(now) <= 60 ? estimatedEnd : date
                } else {
                    anchor = date
                }
                let expires = anchor.addingTimeInterval(10 * 60)
                guard expires.timeIntervalSince(now) > 0.5 else { return nil }
                return min(now.addingTimeInterval(15), expires)
            }
            let sourcePath = text(1)
            let sourceFileName = sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "recording"
            if let path = sourcePath {
                let raw = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                let candidate = raw.standardizedFileURL.resolvingSymlinksInPath()
                let isInside = candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
                let supported = ["m4a", "qta"].contains(candidate.pathExtension.lowercased())
                if isInside && supported {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                       attributes[.type] as? FileAttributeType == .typeRegular,
                       let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0,
                       let modified = attributes[.modificationDate] as? Date {
                        let values = try? candidate.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                        if values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus == .current {
                            let deadline = modified.addingTimeInterval(60)
                            if deadline > Date() {
                                // Do not assume the file is finished: check again after it has
                                // remained unchanged for the existing 60-second safety window.
                                readyAfter = deadline
                            } else {
                                audioURL = candidate
                            }
                        } else {
                            readyAfter = retryRecentUnavailable()
                        }
                    } else {
                        readyAfter = retryRecentUnavailable()
                    }
                }
            } else {
                readyAfter = retryRecentUnavailable()
            }
            entries.append(Recording(id: id, title: title, date: date, duration: duration, sourceFileName: sourceFileName, sourcePath: sourcePath, audioURL: audioURL, readyAfter: readyAfter))
            resultCode = sqlite3_step(statement)
        }
        guard resultCode == SQLITE_DONE else {
            throw RecordingError(message: "Could not read the recording list. Please try again.")
        }
        return entries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

@MainActor
final class MemoStore: ObservableObject {
    @Published private(set) var memos: [Memo] = []
    @Published private(set) var hiddenMemos: [HiddenMemo] = []
    @Published var errorMessage: String?
    @Published private(set) var dataDirectory: URL
    @Published private(set) var hasActiveTranscription = false
    @Published private(set) var wasTranscriptionCancelled = false
    @Published private(set) var audioLinksEnabled: Bool

    private let service = TranscriptionService()
    private var scopedDirectory: URL?
    private let recordingsDirectories: [URL]
    private var preparationTimer: Timer?
    private var runningID: String?
    private var failedIDs = Set<String>()
    private var localNames: [String: String] = [:]
    private var disabledLinkCleanupPending = false
    private let defaults = UserDefaults.standard
    private let directoryBookmarkKey = "MemoBridge.dataDirectoryBookmark"
    private let directoryPathKey = "MemoBridge.dataDirectoryPath"

    init(recordingsDirectories: [URL]? = nil, dataDirectoryOverride: URL? = nil) {
        let defaults = UserDefaults.standard
        var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("memobridge", isDirectory: true)
        var accessed: URL?
        if let dataDirectoryOverride {
            dir = dataDirectoryOverride
        } else if let bookmark = defaults.data(forKey: "MemoBridge.dataDirectoryBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                dir = url
                if url.startAccessingSecurityScopedResource() { accessed = url }
            }
        } else if let path = defaults.string(forKey: "MemoBridge.dataDirectoryPath") {
            dir = URL(fileURLWithPath: path, isDirectory: true)
        }
        self.dataDirectory = dir
        self.scopedDirectory = accessed
        self.recordingsDirectories = recordingsDirectories ?? VoiceMemoReader.defaultDirectories
        self.audioLinksEnabled = dataDirectoryOverride == nil && defaults.bool(forKey: "MemoBridge.audioLinksEnabled")
        // Old versions saved an explicit off state but left their link behind.
        // Do not clean up a fresh install where the preference was never set.
        self.disabledLinkCleanupPending = dataDirectoryOverride == nil &&
            defaults.object(forKey: "MemoBridge.audioLinksEnabled") != nil && !self.audioLinksEnabled
        refresh()
    }

    deinit {
        preparationTimer?.invalidate()
        scopedDirectory?.stopAccessingSecurityScopedResource()
    }

    func setDataDirectory(_ url: URL) {
        guard !hasActiveTranscription else {
            errorMessage = "Wait for transcription to finish before changing the data folder."
            return
        }
        scopedDirectory?.stopAccessingSecurityScopedResource()
        scopedDirectory = nil
        if url.startAccessingSecurityScopedResource() { scopedDirectory = url }
        dataDirectory = url
        defaults.set(url.path, forKey: directoryPathKey)
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: directoryBookmarkKey)
        } else {
            defaults.removeObject(forKey: directoryBookmarkKey)
        }
        refresh()
    }

    func setAudioLinksEnabled(_ enabled: Bool) {
        let previous = audioLinksEnabled
        if !enabled {
            do {
                _ = try AudioLinkManager.remove(in: dataDirectory, sourceDirectories: recordingsDirectories)
            } catch {
                // Restore the previous state if the link could not be safely
                // removed; the user can fix the conflict and try again.
                audioLinksEnabled = previous
                defaults.set(previous, forKey: "MemoBridge.audioLinksEnabled")
                errorMessage = "Cannot remove the Voice Memos link: \(error.localizedDescription)"
                return
            }
        }
        audioLinksEnabled = enabled
        defaults.set(enabled, forKey: "MemoBridge.audioLinksEnabled")
        refresh()
    }

    func transcriptURL(for memo: Memo) -> URL {
        memo.transcriptURL ?? TranscriptDocumentStore.preferredURL(recordingID: memo.id,
            sourceFileName: memo.sourceFileName, directory: dataDirectory)
    }

    /// Names are local to MemoBridge; the Apple recording and JSON filename remain unchanged.
    @discardableResult
    func rename(_ memo: Memo, to input: String) -> Bool {
        do {
            let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw RecordingError(message: "Enter a recording name.") }
            guard title.count <= 1000 else { throw RecordingError(message: "Recording names can contain at most 1000 characters.") }
            guard !title.unicodeScalars.contains(where: LocalMemoNames.isForbiddenControl) else {
                throw RecordingError(message: "Recording names cannot contain line breaks or control characters.")
            }
            guard !hasActiveTranscription else { throw RecordingError(message: "Wait for transcription to finish before renaming.") }
            guard memos.contains(where: { $0.id == memo.id }) else {
                throw RecordingError(message: "This recording is no longer in the list. Refresh and try again.")
            }
            try ensureDataDirectoryOutsideRecordings()
            try MemoIndex.setName(id: memo.id, name: title, in: dataDirectory)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func ensureDataDirectoryOutsideRecordings() throws {
        let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        for candidate in recordingsDirectories {
            let source = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
            guard directory.path != source.path && !directory.path.hasPrefix(prefix) else {
                throw HiddenRecordingsError.message("The data folder cannot be inside the Voice Memos recordings folder.")
            }
        }
    }

    /// Hiding only changes our local mapping; the original audio and transcript remain intact.
    @discardableResult
    func hideMemo(_ memo: Memo) -> Bool {
        do {
            guard !hasActiveTranscription else {
                throw HiddenRecordingsError.message("Wait for the current transcription to finish before removing a recording from MemoBridge.")
            }
            guard memos.contains(where: { $0.id == memo.id }) else {
                throw HiddenRecordingsError.message("This recording is no longer in the list. Refresh and try again.")
            }
            try ensureDataDirectoryOutsideRecordings()
            // Coordinate with GUI and CLI transcription; never cancel an active job.
            let directory = dataDirectory.appendingPathComponent("transcripts", isDirectory: true)
            let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
            for candidate in recordingsDirectories {
                let source = candidate.standardizedFileURL.resolvingSymlinksInPath()
                let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
                guard resolved.path != source.path && !resolved.path.hasPrefix(prefix) else {
                    throw HiddenRecordingsError.message("The transcripts folder cannot point into Voice Memos.")
                }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(".memobridge-transcription.lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else {
                throw HiddenRecordingsError.message("Cannot check the transcription lock: \(String(cString: strerror(errno))).")
            }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw HiddenRecordingsError.message("A transcription is running. Wait for it to finish before removing a recording.")
                }
                throw HiddenRecordingsError.message("Cannot check the transcription lock: \(String(cString: strerror(errno))).")
            }
            defer { flock(fd, LOCK_UN) }
            try HiddenRecordings.hide(HiddenRecordingSnapshot(id: memo.id, title: memo.title, date: memo.date), in: dataDirectory)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// If the original is missing, removing the tombstone allows it to appear
    /// again if Voice Memos later restores or syncs the same recording ID.
    @discardableResult
    func restoreMemo(id: String) -> Bool {
        do {
            try ensureDataDirectoryOutsideRecordings()
            try HiddenRecordings.restore(id: id, in: dataDirectory)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Find the document by recording ID, even if Apple changes the source filename.
    /// Legacy documents are migrated under the same lock used by transcription.
    private func resolvedTranscript(for recording: Recording) throws -> URL? {
        let fm = FileManager.default
        let folder = dataDirectory.appendingPathComponent("transcripts", isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else { return nil }
        let hash = SHA256.hash(data: Data(recording.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let matches = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("--\(hash).json") }
        guard matches.count <= 1 else {
            throw RecordingError(message: "Multiple transcript documents match a recording. Existing files were kept for review.")
        }
        var existingDocument: TranscriptDocument?
        if let current = matches.first {
            let document = try TranscriptDocumentStore.read(url: current)
            guard document.recordingID == recording.id else {
                throw RecordingError(message: "A transcript document has the wrong recording ID. Existing files were kept.")
            }
            existingDocument = document
        }
        let legacy = try LocalMemoNames.transcriptURL(id: recording.id, title: localNames[recording.id], directory: dataDirectory)
        guard fm.fileExists(atPath: legacy.path) else { return matches.first }
        // No destructive operation occurs if a concurrent CLI is transcribing.
        let fd = open(folder.appendingPathComponent(".memobridge-transcription.lock").path,
                      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw RecordingError(message: "Cannot lock transcripts for migration.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return legacy }
            throw RecordingError(message: "Cannot lock transcripts for migration.")
        }
        defer { flock(fd, LOCK_UN) }
        // Another process may have completed the same migration while we waited.
        if !fm.fileExists(atPath: legacy.path) {
            let refreshed = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("--\(hash).json") }
            guard refreshed.count == 1, try TranscriptDocumentStore.read(url: refreshed[0]).recordingID == recording.id else {
                throw RecordingError(message: "Cannot find the migrated transcript. Existing files were kept.")
            }
            return refreshed[0]
        }
        return try TranscriptDocumentStore.migrateLegacy(recordingID: recording.id,
            sourceFileName: existingDocument?.sourceFileName ?? recording.sourceFileName,
            legacyURL: legacy, directory: dataDirectory)
    }

    /// A different MemoBridge process may be transcribing the indexed item.
    /// Do not reset its status while the shared work lock is held.
    private func transcriptionLockIsHeld() -> Bool {
        let path = dataDirectory.appendingPathComponent("transcripts/.memobridge-transcription.lock").path
        let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    func refresh(preserveError: Bool = false) {
        let previousError = preserveError ? errorMessage : nil
        var cleanupWarning: String?
        var hiddenLoaded = false
        do {
            try ensureDataDirectoryOutsideRecordings()
            if disabledLinkCleanupPending {
                disabledLinkCleanupPending = false
                do { _ = try AudioLinkManager.cleanupPreviouslyDisabled(in: dataDirectory, sourceDirectories: recordingsDirectories, enabledPreference: false) }
                catch { cleanupWarning = "Cannot remove the old Voice Memos link: \(error.localizedDescription)" }
            }
            localNames = try LocalMemoNames.load(from: dataDirectory)
            let indexedStates = try MemoIndex.transcriptionStates(in: dataDirectory)
            let anotherTranscriptionActive = !hasActiveTranscription &&
                indexedStates.values.contains(MemoState.transcribing.rawValue) && transcriptionLockIsHeld()
            // Fail closed on an unreadable/corrupt tombstone file: neither the GUI
            // nor batch processing should silently reprocess hidden recordings.
            let hidden = try HiddenRecordings.load(from: dataDirectory)
            hiddenLoaded = true
            hiddenMemos = hidden.values.map {
                HiddenMemo(id: $0.id, title: $0.title, date: $0.date, isAvailable: false)
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            var foundDirectory: URL?
            var lastError: Error?
            var recordings: [Recording] = []
            for directory in recordingsDirectories {
                do {
                    recordings = try VoiceMemoReader.read(from: directory)
                    foundDirectory = directory
                    break
                } catch { lastError = error }
            }
            guard let foundDirectory else { throw lastError ?? RecordingError(message: "Voice Memos could not be found.") }
            var recordingsByID: [String: Recording] = [:]
            for recording in recordings { recordingsByID[recording.id] = recording }
            hiddenMemos = hidden.values.map { snapshot in
                let current = recordingsByID[snapshot.id]
                return HiddenMemo(id: snapshot.id, title: current?.title ?? snapshot.title,
                                  date: current?.date ?? snapshot.date, isAvailable: current != nil)
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let allMemos = try recordings.map { recording -> Memo in
                let output = try resolvedTranscript(for: recording)
                let state: MemoState
                if runningID == recording.id ||
                    (anotherTranscriptionActive && indexedStates[recording.id] == MemoState.transcribing.rawValue) {
                    state = .transcribing
                } else if recording.readyAfter != nil {
                    state = .preparing
                } else if let output {
                    let doc = try TranscriptDocumentStore.read(url: output)
                    let signature: TranscriptSourceSignature?
                    if output.pathExtension.lowercased() == "txt" {
                        let data = try? Data(contentsOf: output.appendingPathExtension("source.json"))
                        signature = data.flatMap { try? JSONDecoder().decode(TranscriptSourceSignature.self, from: $0) }
                    } else {
                        signature = doc.sourceSignature
                    }
                    let current = recording.audioURL.flatMap { SourceSignature(url: $0) }
                    state = current == nil ? .unavailable :
                        (signature != nil && signature?.size == current?.size && signature?.modificationTime == current?.modificationTime ? .complete : .outdated)
                } else if failedIDs.contains(recording.id) || indexedStates[recording.id] == MemoState.failed.rawValue {
                    state = .failed
                } else {
                    state = recording.audioURL == nil ? .unavailable : .pending
                }
                return Memo(id: recording.id, title: localNames[recording.id] ?? recording.title,
                            date: recording.date, duration: recording.duration, audioURL: recording.audioURL,
                            sourceFileName: recording.sourceFileName, transcriptURL: output, state: state)
            }
            let metadata = zip(recordings, allMemos).map { recording, memo in
                MemoIndexMetadata(id: recording.id, sourceTitle: recording.title, sourcePath: recording.sourcePath,
                                  date: recording.date, duration: recording.duration, transcriptionState: memo.state.rawValue)
            }
            try MemoIndex.syncMetadata(metadata, in: dataDirectory)
            let visibleRecordings = recordings.filter { hidden[$0.id] == nil }
            memos = allMemos.filter { hidden[$0.id] == nil }
            schedulePreparationRefresh(visibleRecordings.compactMap(\.readyAfter).min())
            errorMessage = previousError ?? cleanupWarning
            if audioLinksEnabled {
                do {
                    try AudioLinkManager.synchronize(in: dataDirectory, sourceDirectory: foundDirectory)
                } catch {
                    errorMessage = "Cannot create the Voice Memos folder link: \(error.localizedDescription)"
                }
            }
        } catch {
            schedulePreparationRefresh(nil)
            memos = []
            if !hiddenLoaded { hiddenMemos = [] }
            let failure = error.localizedDescription
            errorMessage = cleanupWarning.map { failure + " " + $0 } ?? failure
        }
    }

    private func schedulePreparationRefresh(_ deadline: Date?) {
        preparationTimer?.invalidate()
        preparationTimer = nil
        guard let deadline else { return }
        // One timer for the earliest waiting file; refresh re-evaluates all files
        // and schedules another one only while at least one still needs waiting.
        let delay = max(0.1, deadline.timeIntervalSinceNow + 0.1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(preserveError: true) }
        }
        preparationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Includes a one-shot CLI job running in another process.
    func isAnyTranscriptionRunning() throws -> Bool {
        if hasActiveTranscription { return true }
        return try TranscriptionCancellationRequest.check(in: dataDirectory, requestStop: false)
    }

    /// Stop the current local or cooperating CLI job before changing models.
    func stopTranscription() async throws {
        let originalDirectory = dataDirectory
        service.cancel()
        let deadline = Date().addingTimeInterval(10)
        while true {
            guard dataDirectory == originalDirectory else {
                throw HiddenRecordingsError.message("The data folder changed. Check the previous transcription before switching models.")
            }
            let locked = try TranscriptionCancellationRequest.check(in: originalDirectory, requestStop: true)
            if !hasActiveTranscription && !locked {
                refresh()
                return
            }
            if Date() >= deadline {
                throw HiddenRecordingsError.message("The other transcription did not stop. Quit the old MemoBridge or command-line process and try again; the model was not changed.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func transcribe(_ memo: Memo) {
        guard !hasActiveTranscription else { return }
        guard memo.transcriptURL == nil else {
            errorMessage = "A transcript already exists. Manage the existing file in Finder before retranscribing."
            return
        }
        guard let audio = memo.audioURL, SourceSignature(url: audio) != nil else {
            errorMessage = "Audio unavailable. Ensure the recording has finished and is downloaded in Voice Memos."
            return
        }
        let output = TranscriptDocumentStore.preferredURL(recordingID: memo.id,
            sourceFileName: memo.sourceFileName, directory: dataDirectory)
        hasActiveTranscription = true
        wasTranscriptionCancelled = false
        runningID = memo.id
        failedIDs.remove(memo.id)
        refresh()
        service.transcribe(audioURL: audio, outputURL: output, recordingID: memo.id, sourceFileName: memo.sourceFileName) { [weak self] result in
            guard let self else { return }
            self.runningID = nil
            self.hasActiveTranscription = false
            switch result {
            case .success:
                self.refresh()
            case .failure(let error):
                if error is TranscriptionCancelled {
                    self.wasTranscriptionCancelled = true
                    self.failedIDs.remove(memo.id)
                } else {
                    self.failedIDs.insert(memo.id)
                }
                self.refresh()
                if !(error is TranscriptionCancelled) { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
