import Foundation

@main
struct TranscriptDocumentTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-transcript-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("transcripts/old.txt")
        let sidecar = legacy.appendingPathExtension("source.json")
        let signature = TranscriptSourceSignature(size: 123, modificationTime: 456)
        try Data("Hello, world! 中文".utf8).write(to: legacy)
        try JSONEncoder().encode(signature).write(to: sidecar)
        let result = try TranscriptDocumentStore.migrateLegacy(recordingID: "id-one", sourceFileName: "source.m4a", legacyURL: legacy, directory: root)
        let document = try TranscriptDocumentStore.read(url: result)
        precondition(document.recordingID == "id-one" && document.text == "Hello, world! 中文" && document.sourceSignature == signature)
        precondition(result.lastPathComponent.hasPrefix("source.m4a--"))
        precondition(!fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: sidecar.path))
        precondition(fm.fileExists(atPath: root.appendingPathComponent("legacy-transcripts/old.txt").path))
        precondition(fm.fileExists(atPath: root.appendingPathComponent("legacy-transcripts/old.txt.source.json").path))
        do {
            try TranscriptDocumentStore.writeNew(document: document, to: result)
            fatalError("Existing documents must not be overwritten")
        } catch {}
        let checkedDocument = try TranscriptDocumentStore.read(url: result)
        precondition(checkedDocument == document)
        let other = TranscriptDocumentStore.preferredURL(recordingID: "id-two", sourceFileName: "source.m4a", directory: root)
        precondition(other != result)
        // Simulate interruption after writing JSON and archiving only the sidecar.
        let oldTwo = root.appendingPathComponent("transcripts/second.txt")
        let oldTwoSidecar = oldTwo.appendingPathExtension("source.json")
        try Data("Second".utf8).write(to: oldTwo)
        try JSONEncoder().encode(signature).write(to: oldTwoSidecar)
        let second = TranscriptDocument(recordingID: "id-two", sourceFileName: "source.m4a", text: "Second", sourceSignature: signature)
        try TranscriptDocumentStore.writeNew(document: second, to: other)
        try fm.moveItem(at: oldTwoSidecar, to: root.appendingPathComponent("legacy-transcripts/second.txt.source.json"))
        let resumed = try TranscriptDocumentStore.migrateLegacy(recordingID: "id-two", sourceFileName: "source.m4a", legacyURL: oldTwo, directory: root)
        precondition(resumed == other && !fm.fileExists(atPath: oldTwo.path))
        // A conflicting preexisting JSON must never replace or move legacy text.
        let oldThree = root.appendingPathComponent("transcripts/third.txt")
        try Data("Keep me".utf8).write(to: oldThree)
        let conflicting = TranscriptDocumentStore.preferredURL(recordingID: "id-three", sourceFileName: "source.m4a", directory: root)
        try TranscriptDocumentStore.writeNew(document: TranscriptDocument(recordingID: "id-three", sourceFileName: "source.m4a", text: "Other", sourceSignature: nil), to: conflicting)
        do {
            _ = try TranscriptDocumentStore.migrateLegacy(recordingID: "id-three", sourceFileName: "source.m4a", legacyURL: oldThree, directory: root)
            fatalError("Conflicting document must not migrate")
        } catch {}
        let keptText = try Data(contentsOf: oldThree)
        precondition(keptText == Data("Keep me".utf8))
        print("Transcript documents: migration, archive, interruption, collision and no-overwrite passed")
    }
}
