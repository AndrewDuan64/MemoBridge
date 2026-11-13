import CryptoKit
import Darwin
import Foundation

/// The source file signature captured when a transcript was produced.
struct TranscriptSourceSignature: Codable, Equatable {
    let size: UInt64
    let modificationTime: TimeInterval
}

/// One document per recording. The file contains only local transcript data;
/// Apple's Voice Memos database and original audio are never modified.
struct TranscriptDocument: Codable, Equatable {
    let version: Int
    let recordingID: String
    let sourceFileName: String
    let text: String
    let sourceSignature: TranscriptSourceSignature?

    init(recordingID: String, sourceFileName: String, text: String,
         sourceSignature: TranscriptSourceSignature?) {
        self.version = 1
        self.recordingID = recordingID
        self.sourceFileName = sourceFileName
        self.text = text
        self.sourceSignature = sourceSignature
    }
}

enum TranscriptDocumentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum TranscriptDocumentStore {
    /// The audio basename makes the source recognizable; the full ID hash keeps
    /// paths unique even if Apple creates multiple recordings with the same name.
    static func preferredURL(recordingID: String, sourceFileName: String, directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(recordingID.utf8)).map { String(format: "%02x", $0) }.joined()
        let basename = (sourceFileName as NSString).lastPathComponent
        var safe = ""
        var count = 0
        for character in basename {
            let part = character == "/" || character == ":" || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "_" : String(character)
            let bytes = part.decomposedStringWithCanonicalMapping.utf8.count
            guard count + bytes <= 120 else { break }
            safe += part
            count += bytes
        }
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if safe.isEmpty { safe = "recording" }
        return directory.appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("\(safe)--\(hash).json")
    }

    /// Discover every current or legacy transcript associated with the stable ID.
    /// Call under the shared transcription lock before publishing a new result.
    static func existingURLs(recordingID: String, directory: URL) throws -> [URL] {
        let hash = SHA256.hash(data: Data(recordingID.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent("transcripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name == "memo-\(hash).txt" || name.hasSuffix("--\(hash).txt") || name.hasSuffix("--\(hash).json")
            }
    }

    /// Reads current JSON documents and, for recovery and compatibility, legacy UTF-8 transcripts.
    static func read(url: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "txt" {
            guard let text = String(data: data, encoding: .utf8) else {
                throw TranscriptDocumentError.message("The legacy transcript is not valid UTF-8; it was not changed.")
            }
            return TranscriptDocument(recordingID: "", sourceFileName: "", text: text, sourceSignature: nil)
        }
        let document: TranscriptDocument
        do { document = try JSONDecoder().decode(TranscriptDocument.self, from: data) }
        catch { throw TranscriptDocumentError.message("Unable to read this transcript document; it was not changed.") }
        guard document.version == 1, !document.recordingID.isEmpty else {
            throw TranscriptDocumentError.message("This transcript document format is not supported; it was not changed.")
        }
        return document
    }

    /// Publish on the same volume with a hard link: existing user files are never replaced.
    static func writeNew(document: TranscriptDocument, to outputURL: URL) throws {
        let fm = FileManager.default
        let folder = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".memobridge-transcript-" + UUID().uuidString + ".tmp")
        defer { try? fm.removeItem(at: staged) }
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw TranscriptDocumentError.message("Unable to create a temporary transcript document.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try handle.write(contentsOf: encoder.encode(document))
        try handle.synchronize()
        do { try fm.linkItem(at: staged, to: outputURL) }
        catch {
            throw TranscriptDocumentError.message("A transcript could not be saved without replacing a file; existing files were kept.")
        }
    }

    /// Must be called while holding the shared transcription lock. Retains the
    /// old files as an archive; an interrupted migration is safe to retry.
    static func migrateLegacy(recordingID: String, sourceFileName: String,
                              legacyURL: URL, directory: URL) throws -> URL {
        let fm = FileManager.default
        guard legacyURL.pathExtension.lowercased() == "txt" else {
            throw TranscriptDocumentError.message("The existing transcript is not a legacy text file.")
        }
        let legacyData = try Data(contentsOf: legacyURL)
        guard let text = String(data: legacyData, encoding: .utf8) else {
            throw TranscriptDocumentError.message("The legacy transcript is not valid UTF-8; it was not changed.")
        }
        let metadataURL = legacyURL.appendingPathExtension("source.json")
        let output = preferredURL(recordingID: recordingID, sourceFileName: sourceFileName, directory: directory)
        let archive = directory.appendingPathComponent("legacy-transcripts", isDirectory: true)
        let archivedText = archive.appendingPathComponent(legacyURL.lastPathComponent)
        let archivedMetadata = archive.appendingPathComponent(metadataURL.lastPathComponent)
        let outputExists = fm.fileExists(atPath: output.path)
        let metadataExists = fm.fileExists(atPath: metadataURL.path)
        let metadataArchived = fm.fileExists(atPath: archivedMetadata.path)
        // A previously archived sidecar is recoverable only when the new JSON
        // already exists (a crash between the two archive moves). Otherwise it
        // may be someone else's file and is left untouched.
        guard !fm.fileExists(atPath: archivedText.path),
              !(metadataExists && metadataArchived),
              !(metadataArchived && !outputExists) else {
            throw TranscriptDocumentError.message("A legacy transcript backup already exists; the files were kept for review.")
        }
        let sourceMetadata = metadataExists ? metadataURL : (metadataArchived ? archivedMetadata : nil)
        let metadataData = try sourceMetadata.map { try Data(contentsOf: $0) }
        let signature: TranscriptSourceSignature?
        if let metadataData {
            do { signature = try JSONDecoder().decode(TranscriptSourceSignature.self, from: metadataData) }
            catch { throw TranscriptDocumentError.message("The legacy transcript metadata cannot be read; the files were kept.") }
        } else { signature = nil }
        let document = TranscriptDocument(recordingID: recordingID, sourceFileName: sourceFileName,
                                          text: text, sourceSignature: signature)
        if outputExists {
            guard try read(url: output) == document else {
                throw TranscriptDocumentError.message("A different transcript document already exists; both files were kept for review.")
            }
        } else {
            try writeNew(document: document, to: output)
        }
        // Verify what reached disk before moving either legacy file.
        guard try read(url: output) == document, try Data(contentsOf: legacyURL) == legacyData,
              try sourceMetadata.map({ try Data(contentsOf: $0) }) == metadataData else {
            throw TranscriptDocumentError.message("The transcript changed during migration; the original files were kept.")
        }
        // Never follow a backup-folder symlink, which might point at Apple data.
        var info = stat()
        if lstat(archive.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw TranscriptDocumentError.message("The legacy backup location is not a folder; existing files were kept.")
            }
        } else if errno != ENOENT {
            throw TranscriptDocumentError.message("Cannot inspect the legacy backup folder; existing files were kept.")
        }
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            // Sidecar first: if interrupted, text remains available for retry.
            if metadataExists {
                try fm.moveItem(at: metadataURL, to: archivedMetadata)
                moved.append((metadataURL, archivedMetadata))
            }
            try fm.moveItem(at: legacyURL, to: archivedText)
            moved.append((legacyURL, archivedText))
        } catch {
            for (old, new) in moved.reversed() { try? fm.moveItem(at: new, to: old) }
            throw TranscriptDocumentError.message("The transcript was saved, but its legacy files could not be archived; please review them.")
        }
        return output
    }
}
