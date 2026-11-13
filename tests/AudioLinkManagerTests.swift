import Foundation

private enum TestFailure: Error { case failed(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

@main
struct AudioLinkManagerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-links-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Recordings", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let legacy = data.appendingPathComponent("audio-links", isDirectory: true)
        let oldLink = legacy.appendingPathComponent("old.m4a")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("recording.m4a"))
        try fm.createSymbolicLink(at: oldLink, withDestinationURL: source.appendingPathComponent("recording.m4a"))

        try AudioLinkManager.synchronize(in: data, sourceDirectory: source)
        let link = data.appendingPathComponent(AudioLinkManager.linkName)
        let target = try fm.destinationOfSymbolicLink(atPath: link.path)
        try require(URL(fileURLWithPath: target).standardizedFileURL == source.standardizedFileURL,
                    "the directory link should target the original source")
        try AudioLinkManager.synchronize(in: data, sourceDirectory: source)
        let entries = try fm.contentsOfDirectory(atPath: data.path).sorted()
        try require(entries == ["Voice Memos", "audio-links"], "there should be one new link and the legacy directory")
        try require((try? fm.destinationOfSymbolicLink(atPath: oldLink.path)) != nil,
                    "legacy links must remain intact")
        let original = try Data(contentsOf: source.appendingPathComponent("recording.m4a"))
        try require(original == Data("original".utf8), "source audio must remain unchanged")
        let fresh = try AudioLinkManager.cleanupPreviouslyDisabled(in: data, sourceDirectories: [source], enabledPreference: nil)
        try require(!fresh && (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                    "an unset preference must not remove a pre-existing link")
        let stillEnabled = try AudioLinkManager.cleanupPreviouslyDisabled(in: data, sourceDirectories: [source], enabledPreference: true)
        try require(!stillEnabled && (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                    "an enabled preference must not remove the link")
        let removed = try AudioLinkManager.cleanupPreviouslyDisabled(in: data, sourceDirectories: [source], enabledPreference: false)
        try require(removed, "an explicitly disabled legacy link should be removed")
        try require((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil, "the link should be gone")
        try require((try? fm.destinationOfSymbolicLink(atPath: oldLink.path)) != nil, "older individual links should remain")
        let sourceAfterRemoval = try Data(contentsOf: source.appendingPathComponent("recording.m4a"))
        try require(sourceAfterRemoval == original, "disabling must not modify the source audio")
        let absent = try AudioLinkManager.remove(in: data, sourceDirectories: [source])
        try require(!absent, "disabling an already absent link should be harmless")
        try AudioLinkManager.synchronize(in: data, sourceDirectory: source)
        let switchedOff = try AudioLinkManager.remove(in: data, sourceDirectories: [source])
        try require(switchedOff, "turning the switch off should remove the matching link")
        let missingSource = root.appendingPathComponent("missing-source", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: missingSource)
        let missingRemoved = try AudioLinkManager.remove(in: data, sourceDirectories: [missingSource])
        try require(missingRemoved, "a broken link to the expected source should be removable")

        let conflictData = root.appendingPathComponent("conflict", isDirectory: true)
        try fm.createDirectory(at: conflictData, withIntermediateDirectories: true)
        let conflict = conflictData.appendingPathComponent(AudioLinkManager.linkName)
        try Data("user data".utf8).write(to: conflict)
        do {
            try AudioLinkManager.synchronize(in: conflictData, sourceDirectory: source)
            throw TestFailure.failed("a file conflict should fail")
        } catch is TestFailure { throw TestFailure.failed("a file conflict should fail") } catch { }
        let conflictContent = try Data(contentsOf: conflict)
        try require(conflictContent == Data("user data".utf8), "conflict must not be replaced")
        do {
            _ = try AudioLinkManager.remove(in: conflictData, sourceDirectories: [source])
            throw TestFailure.failed("a regular file must not be removed")
        } catch is TestFailure { throw TestFailure.failed("a regular file must not be removed") } catch { }
        let conflictAfterRemoval = try Data(contentsOf: conflict)
        try require(conflictAfterRemoval == Data("user data".utf8), "a user file must remain intact")

        try fm.removeItem(at: conflict)
        let missing = root.appendingPathComponent("missing")
        try fm.createSymbolicLink(at: conflict, withDestinationURL: missing)
        do {
            try AudioLinkManager.synchronize(in: conflictData, sourceDirectory: source)
            throw TestFailure.failed("a broken or different link should fail")
        } catch is TestFailure { throw TestFailure.failed("a broken or different link should fail") } catch { }
        let conflictTarget = try fm.destinationOfSymbolicLink(atPath: conflict.path)
        try require(conflictTarget == missing.path, "existing broken link must not be replaced")
        do {
            _ = try AudioLinkManager.remove(in: conflictData, sourceDirectories: [source])
            throw TestFailure.failed("an unrelated symbolic link must not be removed")
        } catch is TestFailure { throw TestFailure.failed("an unrelated symbolic link must not be removed") } catch { }
        let retainedTarget = try fm.destinationOfSymbolicLink(atPath: conflict.path)
        try require(retainedTarget == missing.path, "unrelated links must remain intact")

        try fm.removeItem(at: conflict)
        try fm.createDirectory(at: conflict, withIntermediateDirectories: false)
        do {
            _ = try AudioLinkManager.remove(in: conflictData, sourceDirectories: [source])
            throw TestFailure.failed("a regular directory must not be removed")
        } catch is TestFailure { throw TestFailure.failed("a regular directory must not be removed") } catch { }
        var isDirectory: ObjCBool = false
        try require(fm.fileExists(atPath: conflict.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                    "a user directory must remain intact")

        let withinSource = source.appendingPathComponent("should-not-create", isDirectory: true)
        do {
            try AudioLinkManager.synchronize(in: withinSource, sourceDirectory: source)
            throw TestFailure.failed("the original recordings folder must never be a data destination")
        } catch is TestFailure { throw TestFailure.failed("source directory should be rejected") } catch { }
        try require(!fm.fileExists(atPath: withinSource.path), "source folder must not be modified")
        print("Audio folder link: create, disable, missing source and conflicts passed")
    }
}
