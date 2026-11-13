import Foundation
import Combine

/// Shows tags from the data folder's shared transactional recording index.
@MainActor
final class TagStore: ObservableObject {
    @Published private(set) var assignments: [String: [String]] = [:]
    @Published var errorMessage: String?
    private var directory: URL?
    private var canSave = false

    var allTags: [String] {
        var canonical: [String: String] = [:]
        for tag in assignments.values.flatMap({ $0 }) {
            let key = Self.key(tag)
            if canonical[key] == nil { canonical[key] = tag }
        }
        return canonical.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func tags(for id: String) -> [String] { assignments[id] ?? [] }

    func hasTag(_ tag: String, memoID: String) -> Bool {
        tags(for: memoID).contains { Self.key($0) == Self.key(tag) }
    }

    func load(directory: URL) {
        self.directory = directory
        assignments = [:]
        errorMessage = nil
        canSave = false
        do {
            assignments = try MemoIndex.tags(in: directory)
            canSave = true
        } catch {
            errorMessage = "Could not read tags. Existing data was not changed. \(error.localizedDescription)"
        }
    }

    func add(_ input: String, memoID: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 80, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            errorMessage = "Tags must be at most 80 characters and contain no line breaks."
            return
        }
        change(trimmed, memoID: memoID, add: true)
    }

    func remove(_ tag: String, memoID: String) {
        change(tag, memoID: memoID, add: false)
    }

    private func change(_ tag: String, memoID: String, add: Bool) {
        guard canSave, let directory else { return }
        do {
            try MemoIndex.changeTag(tag, memoID: memoID, add: add, in: directory)
            assignments = try MemoIndex.tags(in: directory)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save tags: \(error.localizedDescription)"
        }
    }

    private static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
