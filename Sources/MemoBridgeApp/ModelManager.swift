import Foundation
import Combine
import CryptoKit
import SwiftUI

/// Multilingual models in whisper.cpp's GGML format. The raw values for Base
/// and Small are retained so existing installations keep their selections.
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny, fast, accurate, medium, turbo, large

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: return "Tiny"
        case .fast: return "Base"
        case .accurate: return "Small"
        case .medium: return "Medium"
        case .turbo: return "Large v3 Turbo"
        case .large: return "Large v3"
        }
    }
    var detail: String {
        switch self {
        case .tiny: return "78 MB · fastest · lowest accuracy"
        case .fast: return "148 MB · fast · basic accuracy · bundled"
        case .accurate: return "488 MB · moderate speed · improved accuracy"
        case .medium: return "1.53 GB · slow · higher accuracy · more memory"
        case .turbo: return "1.62 GB · faster than Large v3 · high accuracy · more memory"
        case .large: return "3.10 GB · slowest · highest memory use · high accuracy"
        }
    }
    var fileName: String {
        switch self {
        case .tiny: return "ggml-tiny.bin"
        case .fast: return "ggml-base.bin"
        case .accurate: return "ggml-small.bin"
        case .medium: return "ggml-medium.bin"
        case .turbo: return "ggml-large-v3-turbo.bin"
        case .large: return "ggml-large-v3.bin"
        }
    }
    fileprivate var sha256: String {
        switch self {
        case .tiny: return "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        case .fast: return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .accurate: return "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        case .medium: return "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        case .turbo: return "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .large: return "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        }
    }
    fileprivate var url: URL {
        // Pin a model repository revision; never use a mutable model URL.
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(fileName)")!
    }
}

private enum ModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Move URLSession's temporary file into our staging area before its callback returns.
/// A cancelled or failed transfer is never published as an installed model.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let staged: URL
    private let progress: (Double?) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var completed = false

    init(staged: URL, progress: @escaping (Double?) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.staged = staged
        self.progress = progress
        self.completion = completion
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        completion(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { progress(nil); return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            finish(.failure(ModelError.message("Model download failed. Please check your network and try again.")))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

/// Downloads and verifies models in the user's data directory before switching.
/// The bundled base model remains the default until a selection succeeds.
@MainActor
final class WhisperModelManager: ObservableObject {
    @Published private(set) var selected: WhisperModel
    @Published private(set) var activeModel: WhisperModel?
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private var operation: UUID?
    private var session: URLSession?
    private var download: URLSessionDownloadTask?
    private var stageURL: URL?
    private var isTranscriptionRunning: (() throws -> Bool)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selected = WhisperModel(rawValue: defaults.string(forKey: "MemoBridge.selectedWhisperModel") ?? "") ?? .fast
    }

    func setTranscriptionCheck(_ check: (() throws -> Bool)?) {
        isTranscriptionRunning = check
    }

    /// Once verification succeeds this updates the same setting consumed by the CLI and GUI.
    func select(_ model: WhisperModel, dataDirectory: URL) {
        guard activeModel == nil else { return }
        let id = UUID()
        operation = id
        activeModel = model
        progress = nil
        errorMessage = nil
        message = "Preparing \(model.label)…"
        let directory = dataDirectory.appendingPathComponent("models", isDirectory: true)
        let destination = directory.appendingPathComponent(model.fileName)
        let staged = directory.appendingPathComponent(".memobridge-model-\(id.uuidString).tmp")
        stageURL = staged
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("models/\(model.fileName)")

        Task.detached(priority: .utility) { [weak self] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) || Self.isSymbolicLink(destination) {
                    try Self.verify(destination, expected: model.sha256)
                    await self?.finishSelection(model, destination: destination, id: id)
                } else if let bundled, fm.isReadableFile(atPath: bundled.path) {
                    try fm.copyItem(at: bundled, to: staged)
                    try Self.verify(staged, expected: model.sha256)
                    await self?.publishSelection(model, staged: staged, destination: destination, id: id)
                } else {
                    await self?.startDownload(model, staged: staged, destination: destination, id: id)
                }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                await self?.finishError(error, id: id)
            }
        }
    }

    func cancel() {
        operation = nil
        download?.cancel()
        session?.invalidateAndCancel()
        download = nil
        session = nil
        if let stageURL { try? FileManager.default.removeItem(at: stageURL) }
        stageURL = nil
        activeModel = nil
        progress = nil
        message = "Model selection cancelled."
    }

    private func startDownload(_ model: WhisperModel, staged: URL, destination: URL, id: UUID) {
        guard operation == id else { return }
        message = "Downloading \(model.label)…"
        let delegate = ModelDownloadDelegate(staged: staged, progress: { [weak self] value in
            DispatchQueue.main.async {
                guard self?.operation == id else { return }
                self?.progress = value
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.operation == id else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
                self.session?.finishTasksAndInvalidate()
                self.session = nil
                self.download = nil
                switch result {
                case .success:
                    self.message = "Verifying \(model.label)…"
                    self.progress = nil
                    Task.detached(priority: .utility) { [weak self] in
                        do {
                            try Self.verify(staged, expected: model.sha256)
                            await self?.publishSelection(model, staged: staged, destination: destination, id: id)
                        } catch {
                            try? FileManager.default.removeItem(at: staged)
                            await self?.finishError(error, id: id)
                        }
                    }
                case .failure(let error): self.finishError(error, id: id)
                }
            }
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: model.url)
        self.session = session
        self.download = task
        task.resume()
    }

    private func publishSelection(_ model: WhisperModel, staged: URL, destination: URL, id: UUID) {
        guard operation == id else { try? FileManager.default.removeItem(at: staged); return }
        do {
            // Hard links publish a complete file atomically without overwriting a user file.
            try FileManager.default.linkItem(at: staged, to: destination)
            try? FileManager.default.removeItem(at: staged)
            finishSelection(model, destination: destination, id: id)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            finishError(ModelError.message("A model file already exists or could not be saved. The existing file was not replaced."), id: id)
        }
    }

    private func finishSelection(_ model: WhisperModel, destination: URL, id: UUID) {
        guard operation == id else { return }
        do {
            if model != selected, try isTranscriptionRunning?() == true {
                throw ModelError.message("A transcription started during the download. The model was not changed; select it again to stop that transcription.")
            }
        } catch {
            finishError(error, id: id)
            return
        }
        defaults.set(destination.path, forKey: "whisperModelPath")
        defaults.set(model.rawValue, forKey: "MemoBridge.selectedWhisperModel")
        selected = model
        operation = nil
        stageURL = nil
        activeModel = nil
        progress = nil
        message = "\(model.label) is ready."
    }

    private func finishError(_ error: Error, id: UUID) {
        guard operation == id else { return }
        if let stageURL { try? FileManager.default.removeItem(at: stageURL) }
        stageURL = nil
        operation = nil
        activeModel = nil
        progress = nil
        message = nil
        errorMessage = error.localizedDescription
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    nonisolated private static func verify(_ url: URL, expected: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModelError.message("The model path is not a regular file. No existing file was changed.")
        }
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw ModelError.message("Model verification failed. The selected model was not changed.")
        }
    }
}

/// A small, reusable settings panel; choosing a model never changes selection
/// until the complete download has passed its checksum.
struct ModelSettingsView: View {
    let dataDirectory: URL
    let isTranscriptionRunning: () throws -> Bool
    let stopTranscription: () async throws -> Void
    @StateObject private var manager = WhisperModelManager()
    @State private var modelToSwitch: WhisperModel?
    @State private var showingConfirmation = false
    @State private var stopping = false
    @State private var stopError: String?
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Multilingual Whisper models. Sizes are approximate downloads; speed and accuracy depend on your Mac, language and audio. Larger models generally need more memory.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(WhisperModel.allCases) { model in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.label).fontWeight(.medium)
                        Text(model.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.selected == model {
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(manager.selected == model ? "Use in Data Folder" : "Select") {
                        choose(model)
                    }
                    .disabled(manager.activeModel != nil || stopping)
                }
            }
            if let active = manager.activeModel {
                HStack {
                    if let progress = manager.progress {
                        ProgressView(value: progress).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { manager.cancel() }
                }
                .accessibilityLabel("Preparing \(active.label)")
            }
            if let message = manager.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if stopping {
                HStack { ProgressView().controlSize(.small); Text("Stopping transcription…").font(.caption) }
            }
            if let stopError {
                Text(stopError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .alert("Stop transcription and switch model?", isPresented: $showingConfirmation) {
            Button("Stop and Switch", role: .destructive) {
                guard let model = modelToSwitch else { return }
                stopping = true
                stopError = nil
                stopTask = Task {
                    do {
                        try await stopTranscription()
                        guard !Task.isCancelled else { return }
                        manager.select(model, dataDirectory: dataDirectory)
                    } catch {
                        guard !Task.isCancelled else { return }
                        stopError = error.localizedDescription
                    }
                    stopping = false
                }
            }
            Button("Keep Transcribing", role: .cancel) { modelToSwitch = nil }
        } message: {
            Text("Switching models will stop the current transcription immediately. No partial transcript will be saved; you can transcribe it again after switching.")
        }
        .onAppear { manager.setTranscriptionCheck(isTranscriptionRunning) }
        .onChange(of: dataDirectory) { _ in
            stopTask?.cancel()
            stopping = false
            if manager.activeModel != nil { manager.cancel() }
        }
        .onDisappear {
            stopTask?.cancel()
            if manager.activeModel != nil { manager.cancel() }
            manager.setTranscriptionCheck(nil)
        }
    }

    private func choose(_ model: WhisperModel) {
        stopError = nil
        do {
            if try model != manager.selected && isTranscriptionRunning() {
                modelToSwitch = model
                showingConfirmation = true
            } else {
                manager.select(model, dataDirectory: dataDirectory)
            }
        } catch {
            stopError = error.localizedDescription
        }
    }
}
