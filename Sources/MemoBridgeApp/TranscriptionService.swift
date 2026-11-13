import Foundation
import Combine
import Darwin

/// A cancellation token shared by the GUI and worker thread. Cross-process
/// requests are keyed to the lock owner's random job ID, never to a PID.
private final class TranscriptionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var markerURL: URL?

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let local = cancelled
        lock.unlock()
        if local || markerURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            throw TranscriptionCancelled()
        }
    }

    /// Publishing and a local cancellation cannot race each other.
    func publish(_ action: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || markerURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            throw TranscriptionCancelled()
        }
        try action()
    }
}

struct TranscriptionCancelled: LocalizedError {
    var errorDescription: String? { "Transcription stopped. No partial transcript was saved." }
}

/// Cooperatively asks the process holding the shared lock to stop. No PID is
/// read or signalled; a stale request cannot affect a later recording.
enum TranscriptionCancellationRequest {
    static func check(in directory: URL, requestStop: Bool) throws -> Bool {
        let folder = directory.appendingPathComponent("transcripts", isDirectory: true)
        let fd = open(folder.appendingPathComponent(".memobridge-transcription.lock").path,
                      O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw TranscriptionError.message("Cannot check whether another transcription is running.")
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw TranscriptionError.message("Cannot check the transcription lock.")
        }
        if requestStop {
            var bytes = [UInt8](repeating: 0, count: 64)
            let size = pread(fd, &bytes, bytes.count, 0)
            if size > 0, let raw = String(bytes: bytes.prefix(Int(size)), encoding: .utf8),
               let id = UUID(uuidString: raw), id.uuidString == raw {
                let marker = folder.appendingPathComponent(".memobridge-cancel-" + id.uuidString)
                let signal = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
                if signal >= 0 { close(signal) }
                else if errno != EEXIST {
                    throw TranscriptionError.message("Cannot request that the current transcription stop.")
                }
            }
            // A process from an older app may not publish a job ID. Keep
            // waiting, then report failure instead of signalling an unknown PID.
        }
        return true
    }
}

/// Runs at most one local whisper.cpp transcription per app instance.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var isRunning = false
    private var cancellation: TranscriptionCancellation?

    func cancel() { cancellation?.cancel() }

    /// Writes a new transcript only; it never replaces an existing document.
    func transcribe(audioURL: URL, outputURL: URL, recordingID: String, sourceFileName: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isRunning else {
            completion(.failure(TranscriptionError.message("A recording is already being transcribed. Please wait.")))
            return
        }

        let defaults = UserDefaults.standard
        let whisperPath = defaults.string(forKey: "whisperExecutablePath") ?? ""
        let modelPath = defaults.string(forKey: "whisperModelPath") ?? ""
        let cancellation = TranscriptionCancellation()
        self.cancellation = cancellation
        isRunning = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try Self.perform(
                    audioURL: audioURL,
                    outputURL: outputURL,
                    recordingID: recordingID,
                    sourceFileName: sourceFileName,
                    whisperPath: whisperPath,
                    modelPath: modelPath,
                    cancellation: cancellation
                )
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.cancellation = nil
                completion(result)
            }
        }
    }

    nonisolated private static func perform(
        audioURL: URL, outputURL: URL, recordingID: String, sourceFileName: String,
        whisperPath: String, modelPath: String, cancellation: TranscriptionCancellation
    ) throws -> URL {
        let fm = FileManager.default
        try cancellation.check()
        guard fm.isReadableFile(atPath: audioURL.path) else {
            throw TranscriptionError.message("Cannot read the recording. Ensure it is downloaded and MemoBridge has access.")
        }
        // GUI and CLI can run as distinct processes. Keep the lock file in the
        // shared transcript directory and never unlink it while other jobs run.
        let transcriptDirectory = outputURL.deletingLastPathComponent()
        try fm.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let lockPath = transcriptDirectory.appendingPathComponent(".memobridge-transcription.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            throw TranscriptionError.message("Unable to create the transcription lock: \(String(cString: strerror(errno)))")
        }
        defer { close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw TranscriptionError.message("Another MemoBridge transcription is running. Please try again later.")
            }
            throw TranscriptionError.message("Unable to acquire the transcription lock: \(String(cString: strerror(errno)))")
        }
        defer { flock(lockDescriptor, LOCK_UN) }
        try cancellation.check()
        let jobID = UUID().uuidString
        let marker = transcriptDirectory.appendingPathComponent(".memobridge-cancel-" + jobID)
        cancellation.markerURL = marker
        defer { try? fm.removeItem(at: marker) }
        let jobBytes = Array(jobID.utf8)
        guard ftruncate(lockDescriptor, 0) == 0,
              jobBytes.withUnsafeBytes({ pwrite(lockDescriptor, $0.baseAddress, $0.count, 0) }) == jobBytes.count else {
            throw TranscriptionError.message("Unable to register the transcription job.")
        }
        try cancellation.check()
        // A separate process may have hidden this recording after it was
        // queued. Recheck under the same lock used by the hide operation.
        let dataDirectory = transcriptDirectory.deletingLastPathComponent()
        if try HiddenRecordings.contains(recordingID, in: dataDirectory) {
            throw TranscriptionError.message("This recording was removed from MemoBridge and will not be transcribed.")
        }
        // Recheck the destination under the same lock used by migration.
        let expected = TranscriptDocumentStore.preferredURL(recordingID: recordingID, sourceFileName: sourceFileName, directory: dataDirectory)
        guard expected.standardizedFileURL == outputURL.standardizedFileURL else {
            throw TranscriptionError.message("The recording location changed. Refresh and try again.")
        }
        guard try TranscriptDocumentStore.existingURLs(recordingID: recordingID, directory: dataDirectory).isEmpty else {
            throw TranscriptionError.message("A transcript for this recording already exists; it was not overwritten. Refresh and review it.")
        }
        let initialAudio = try AudioSignature(url: audioURL)
        let bundledWhisper = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli").path
        let whisper = try findExecutable(
            configured: whisperPath,
            candidates: [bundledWhisper, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].compactMap { $0 },
            description: "whisper-cli",
            guidance: "The bundled transcription engine may be missing or damaged. Rebuild or reinstall MemoBridge."
        )
        let userModel = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModel = outputURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models/ggml-base.bin")
        let bundledModel = Bundle.main.resourceURL?.appendingPathComponent("models/ggml-base.bin")
        let model: URL
        if !userModel.isEmpty {
            model = URL(fileURLWithPath: (userModel as NSString).expandingTildeInPath)
        } else if let bundledModel, fm.isReadableFile(atPath: bundledModel.path) {
            model = bundledModel
        } else {
            model = defaultModel
        }
        guard fm.isReadableFile(atPath: model.path), !model.hasDirectoryPath else {
            throw TranscriptionError.message("Whisper model not found. Select a model in Settings.")
        }
        guard !fm.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.message("The transcript already exists and was not overwritten. Back up or remove it before trying again.")
        }

        let temp = fm.temporaryDirectory.appendingPathComponent("MemoBridge-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let wav = temp.appendingPathComponent("audio.wav")
        let prefix = temp.appendingPathComponent("transcript")
        let log = temp.appendingPathComponent("process.log")

        try AudioConverter.convertToWAV(source: audioURL, destination: wav, checkCancelled: { try cancellation.check() })
        try cancellation.check()
        try run(executable: whisper,
                arguments: ["-m", model.path, "-f", wav.path, "-l", "auto", "-t", "2", "-otxt", "-of", prefix.path],
                logURL: log, name: "Whisper transcription", cancellation: cancellation)
        try cancellation.check()
        guard initialAudio == (try AudioSignature(url: audioURL)) else {
            throw TranscriptionError.message("The recording changed during transcription. No transcript was saved; please retry.")
        }
        let generated = prefix.appendingPathExtension("txt")
        guard let text = try? String(contentsOf: generated, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.message("Whisper did not produce a valid transcript. Check the recording and model.")
        }
        let signature = TranscriptSourceSignature(size: initialAudio.size, modificationTime: initialAudio.modified.timeIntervalSince1970)
        let document = TranscriptDocument(recordingID: recordingID, sourceFileName: sourceFileName,
                                          text: text, sourceSignature: signature)
        try cancellation.publish { try TranscriptDocumentStore.writeNew(document: document, to: outputURL) }
        return outputURL
    }

    nonisolated private static func findExecutable(configured: String, candidates: [String], description: String, guidance: String) throws -> URL {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = value.isEmpty ? candidates : [(value as NSString).expandingTildeInPath]
        if let found = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        throw TranscriptionError.message("Could not find \(description). \(guidance)")
    }

    nonisolated private static func run(executable: URL, arguments: [String], logURL: URL, name: String,
                                       cancellation: TranscriptionCancellation) throws {
        let fm = FileManager.default
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.truncate(atOffset: 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        try cancellation.check()
        do { try process.run() } catch {
            throw TranscriptionError.message("Unable to launch \(name): \(error.localizedDescription)")
        }
        while process.isRunning {
            do { try cancellation.check() }
            catch {
                _ = kill(process.processIdentifier, SIGTERM)
                // Whisper may be busy in native code; stop the owned child even
                // if it does not respond promptly to SIGTERM.
                for _ in 0..<10 where process.isRunning { usleep(50_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw error
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            // Do not echo the program output, which may contain private transcript text.
            throw TranscriptionError.message("\(name) failed (exit code \(process.terminationStatus)). Check the engine, model, and audio format.")
        }
    }
}

private struct AudioSignature: Equatable {
    let size: UInt64
    let modified: Date
    init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date, size > 0 else {
            throw TranscriptionError.message("The recording is empty or unreadable. Wait for synchronization to finish.")
        }
        self.size = size
        self.modified = modified
    }
}

private enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
