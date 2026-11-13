import Foundation

@main
struct TagStoreTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MemoBridge-tags-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        let tags = TagStore()
        tags.load(directory: one)
        tags.add(" Meeting ", memoID: "a")
        tags.add("meeting", memoID: "a")
        tags.add("MEETING", memoID: "b")
        precondition(tags.tags(for: "a") == ["Meeting"])
        precondition(tags.tags(for: "b") == ["Meeting"])
        precondition(tags.allTags == ["Meeting"])
        let reopened = TagStore()
        reopened.load(directory: one)
        precondition(reopened.hasTag("meeting", memoID: "a"))
        reopened.remove("MEETING", memoID: "a")
        precondition(!reopened.hasTag("meeting", memoID: "a") && reopened.hasTag("meeting", memoID: "b"))
        reopened.load(directory: two)
        precondition(reopened.allTags.isEmpty)
        let corruptDirectory = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let bad = corruptDirectory.appendingPathComponent("tags.json")
        try Data("bad json".utf8).write(to: bad)
        reopened.load(directory: corruptDirectory)
        reopened.add("Work", memoID: "a")
        let preserved = try Data(contentsOf: bad)
        precondition(preserved == Data("bad json".utf8))
        precondition(reopened.errorMessage != nil)
        print("Tags: persistence, case-insensitive matching, removal, directory switching, corrupt file protection passed")
    }
}
