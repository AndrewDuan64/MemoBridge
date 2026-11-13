import Foundation

/// The persisted identifier remains authoritative even if the original is not
/// currently in Voice Memos. The other fields are recovery-list snapshots.
struct HiddenRecordingSnapshot: Codable, Equatable {
    let id: String
    let title: String
    let date: Date?
}

struct HiddenMemo: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date?
    let isAvailable: Bool
}

enum HiddenRecordingsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// These compatibility methods use the same transactional index as names and tags.
enum HiddenRecordings {
    static func load(from directory: URL) throws -> [String: HiddenRecordingSnapshot] {
        try MemoIndex.hidden(in: directory)
    }

    static func contains(_ id: String, in directory: URL) throws -> Bool {
        try MemoIndex.hidden(in: directory)[id] != nil
    }

    static func hide(_ snapshot: HiddenRecordingSnapshot, in directory: URL) throws {
        try MemoIndex.setHidden(snapshot, in: directory)
    }

    static func restore(id: String, in directory: URL) throws {
        try MemoIndex.restore(id: id, in: directory)
    }
}
