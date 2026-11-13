import Foundation
import Darwin

/// Shared one-shot batch loop; explicit store injection keeps tests isolated.
enum BatchProcessor {
    @MainActor
    static func run(store: MemoStore) async -> Int32 {
        if let message = store.errorMessage {
            fputs("Cannot read recordings: \(message)\n", stderr)
            return 1
        }
        let pendingIDs = store.memos.filter { $0.state == .pending }.map(\.id)
        let unavailable = store.memos.filter { $0.state == .unavailable }.count
        let preparing = store.memos.filter { $0.state == .preparing }.count
        let outdated = store.memos.filter { $0.state == .outdated }.count
        if pendingIDs.isEmpty {
            print("No recordings are awaiting transcription.")
        }
        var success = 0
        var failures = 0
        for (index, id) in pendingIDs.enumerated() {
            // Refresh before each item so a new or previously processed entry is
            // never repeated when a user edits the recording while this runs.
            store.refresh()
            if let message = store.errorMessage {
                fputs("Cannot refresh recordings: \(message)\n", stderr)
                return 1
            }
            guard let memo = store.memos.first(where: { $0.id == id && $0.state == .pending }) else {
                continue
            }
            print("Transcribing \(index + 1)/\(pendingIDs.count)…")
            store.errorMessage = nil
            store.transcribe(memo)
            while store.hasActiveTranscription {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if store.wasTranscriptionCancelled {
                fputs("Transcription stopped; remaining recordings were not started.\n", stderr)
                return 1
            }
            if let message = store.errorMessage {
                fputs("Transcription failed: \(message)\n", stderr)
                failures += 1
                // An unavailable engine or another running task is unlikely to
                // be fixed during this run; allow the next command to retry.
                break
            }
            if store.memos.first(where: { $0.id == id })?.state == .complete {
                success += 1
            } else {
                fputs("The recording state changed and was not marked complete.\n", stderr)
                failures += 1
            }
        }
        print("Complete: transcribed \(success); failed \(failures); preparing \(preparing); unavailable \(unavailable); source changed \(outdated).")
        return failures == 0 ? 0 : 1
    }
}
