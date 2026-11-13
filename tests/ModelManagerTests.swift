// Run with tests/run_model_manager_tests.sh. Uses only a temporary directory and
// the already-downloaded base model; never touches the user's data or network.
import Foundation

private enum Failure: Error { case assertion(String) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.assertion(message) }
}

/// Keep test selections in memory; never write to the user's real preferences.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@main
struct ModelManagerTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("MemoBridge-model-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let defaults = MemoryDefaults(suiteName: nil)!
        let manager = WhisperModelManager(defaults: defaults)

        func waitForCompletion() async throws {
            for _ in 0..<600 {
                if manager.activeModel == nil { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Failure.assertion("model operation timed out")
        }

        let base = temp.appendingPathComponent("models/ggml-base.bin")
        manager.select(.fast, dataDirectory: temp)
        try await waitForCompletion()
        try check(manager.errorMessage == nil, "bundled model should copy and verify successfully")
        try check(manager.selected == .fast, "base model should be selected")
        try check(defaults.string(forKey: "whisperModelPath") == base.path, "model path should point to the chosen data directory")
        try check(fm.fileExists(atPath: base.path), "the verified base model should exist in the data directory")

        // A pre-existing corrupt model is never overwritten or selected.
        let bad = temp.appendingPathComponent("models/ggml-small.bin")
        let original = Data("not a whisper model".utf8)
        try original.write(to: bad)
        manager.select(.accurate, dataDirectory: temp)
        try await waitForCompletion()
        try check(manager.errorMessage != nil, "a corrupted model must fail verification")
        try check(manager.selected == .fast, "a failed model must not become selected")
        try check(defaults.string(forKey: "whisperModelPath") == base.path, "a failed selection must preserve the current model path")
        let stillOriginal = try Data(contentsOf: bad)
        try check(stillOriginal == original, "a pre-existing corrupted model must not be overwritten")

        // A validated model can be selected repeatedly without changing its contents.
        manager.select(.fast, dataDirectory: temp)
        try await waitForCompletion()
        try check(manager.errorMessage == nil, "an already installed valid model should remain usable")

        // A transcription may start in another process while a model is being
        // prepared. Do not change the model underneath it.
        let otherDefaults = MemoryDefaults(suiteName: nil)!
        otherDefaults.set(WhisperModel.accurate.rawValue, forKey: "MemoBridge.selectedWhisperModel")
        otherDefaults.set("previous-model", forKey: "whisperModelPath")
        let guarded = WhisperModelManager(defaults: otherDefaults)
        guarded.setTranscriptionCheck { true }
        guarded.select(.fast, dataDirectory: temp)
        for _ in 0..<600 {
            if guarded.activeModel == nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(guarded.activeModel == nil, "guarded operation should complete")
        try check(guarded.selected == .accurate, "active transcription must preserve the previous model")
        try check(otherDefaults.string(forKey: "whisperModelPath") == "previous-model", "active transcription must preserve the model path")
        try check(guarded.errorMessage != nil, "active transcription must show a reason")
        print("Model manager: offline copy, checksum, repeat selection and conflict checks passed")
    }
}
