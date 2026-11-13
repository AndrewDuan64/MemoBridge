import AppKit
import CryptoKit
import SwiftUI

@MainActor
private final class NotebookUpload: ObservableObject {
    @Published var message = "Connect NotebookLM in Settings or choose your Google OAuth client file."
    @Published var choices: [NotebookChoice] = []
    @Published var busy = false
    @Published var done = false
    @Published var needsVerification = false
    @Published var hasSavedClient = false
    private var api: NotebookAPI?
    private var task: Task<Void, Never>?
    private let recordingID: String
    private let transcriptURL: URL
    private let credentialStore: NotebookCredentialStore
    private var uncertainKey: String?
    private let dataDirectory: URL

    init(recordingID: String, transcriptURL: URL, dataDirectory: URL) {
        self.recordingID = recordingID
        self.transcriptURL = transcriptURL
        self.dataDirectory = dataDirectory
        self.credentialStore = NotebookCredentialStore(dataDirectory: dataDirectory)
    }

    func startSaved() {
        guard !busy else { return }
        do {
            guard let credential = try credentialStore.load() else { return }
            hasSavedClient = true
            let api = NotebookAPI(config: credential.config, credentialStore: credentialStore)
            self.api = api
            message = "Connecting to NotebookLM…"
            busy = true
            task = Task {
                do {
                    try await api.restore(credential)
                    choices = try await api.notebooks()
                    guard !Task.isCancelled else { return }
                    busy = false
                    message = choices.isEmpty ? "No notebooks found. Create one in NotebookLM first." : "Choose a notebook."
                } catch {
                    guard !Task.isCancelled else { return }
                    busy = false
                    message = error.localizedDescription + " You can reconnect below."
                }
            }
        } catch { message = error.localizedDescription }
    }

    func start(clientURL: URL) {
        guard !busy else { return }
        do {
            let config = try NotebookClientConfig.load(clientURL)
            startLogin(config: config)
        } catch { message = error.localizedDescription }
    }

    func reconnect() {
        guard !busy else { return }
        do {
            guard let credential = try credentialStore.load() else { return }
            startLogin(config: credential.config)
        } catch { message = error.localizedDescription }
    }

    private func startLogin(config: NotebookClientConfig) {
        let api = NotebookAPI(config: config, credentialStore: credentialStore)
        self.api = api
        message = "Complete Google sign-in and authorization in your browser."
        choices = []
        busy = true
        done = false
        task = Task {
            do {
                try await api.login()
                guard !Task.isCancelled else { return }
                hasSavedClient = true
                message = "Loading notebooks…"
                choices = try await api.notebooks()
                guard !Task.isCancelled else { return }
                busy = false
                message = choices.isEmpty ? "No notebooks found. Create one in NotebookLM first." : "Choose a notebook."
            } catch {
                guard !Task.isCancelled else { return }
                busy = false
                message = error.localizedDescription
            }
        }
    }

    private func key(notebook: String, data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = SHA256.hash(data: Data((recordingID + "\n" + notebook + "\n" + digest).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "notebookUpload." + identity
    }

    func upload(_ choice: NotebookChoice) {
        guard !busy, let api else { return }
        do {
            let document = try TranscriptDocumentStore.read(url: transcriptURL)
            guard document.recordingID.isEmpty || document.recordingID == recordingID else {
                throw NotebookError.message("The transcript belongs to a different recording; it was not uploaded.")
            }
            let text = document.text
            let data = Data(text.utf8)
            guard !data.isEmpty, data.count <= 1_000_000 else {
                throw NotebookError.message("The transcript must be nonempty UTF-8 text and no larger than 1 MB.")
            }
            let key = key(notebook: choice.name, data: data)
            if let previous = try MemoIndex.claimUpload(key: key, recordingID: recordingID, in: dataDirectory) {
                if previous.hasPrefix("active|") {
                    let name = String(previous.dropFirst("active|".count))
                    checkExisting(api: api, source: name, key: key)
                    return
                }
                if previous.hasPrefix("pending|") {
                    let name = String(previous.dropFirst("pending|".count))
                    checkExisting(api: api, source: name, key: key)
                    return
                }
                uncertainKey = key
                needsVerification = true
                message = "The previous upload result is unknown. Check NotebookLM before allowing a retry."
                return
            }
            // claimUpload atomically recorded uncertainty before the POST.
            busy = true
            message = "Uploading transcript…"
            task = Task {
                do {
                    let source = try await api.createSource(notebook: choice.name, text: text)
                    guard !Task.isCancelled else { return }
                    guard let name = source.name, !name.isEmpty else {
                        throw NotebookError.message("Google did not return a source ID. Check your notebook before retrying.")
                    }
                    try MemoIndex.setUploadState("pending|" + name, key: key, recordingID: recordingID, in: dataDirectory)
                    await poll(api: api, source: name, key: key)
                } catch {
                    guard !Task.isCancelled else { return }
                    busy = false
                    uncertainKey = key
                    needsVerification = true
                    message = "Upload result unknown: \(error.localizedDescription) Check NotebookLM before retrying."
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func checkExisting(api: NotebookAPI, source: String, key: String) {
        busy = true
        message = "Checking the previous upload…"
        task = Task { await poll(api: api, source: source, key: key) }
    }

    private func poll(api: NotebookAPI, source: String, key: String) async {
        do {
            for _ in 0..<30 {
                try Task.checkCancellation()
                let result = try await api.source(name: source)
                switch result.state {
                case "ACTIVE":
                    try MemoIndex.setUploadState("active|" + source, key: key, recordingID: recordingID, in: dataDirectory)
                    busy = false
                    done = true
                    message = "Upload complete. Your source is ready in NotebookLM."
                    return
                case "FAILED":
                    try MemoIndex.setUploadState(nil, key: key, recordingID: recordingID, in: dataDirectory)
                    busy = false
                    message = "Source import failed: \(result.error?.message ?? "Unknown error"). You can retry."
                    return
                default:
                    message = "Processing source. Checking again shortly…"
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            busy = false
            message = "The source is still processing. Its status will be checked before another upload."
        } catch {
            guard !Task.isCancelled else { return }
            busy = false
            if case NotebookError.httpStatus(404) = error {
                do {
                    try MemoIndex.setUploadState(nil, key: key, recordingID: recordingID, in: dataDirectory)
                    message = "The previous source no longer exists. You can upload this transcript again."
                } catch {
                    message = "Could not update upload status: \(error.localizedDescription)"
                }
            } else {
                message = "Could not confirm the import: \(error.localizedDescription) The existing source will be checked next time."
            }
        }
    }

    func allowRetryAfterVerification() {
        guard let key = uncertainKey else { return }
        do {
            try MemoIndex.setUploadState(nil, key: key, recordingID: recordingID, in: dataDirectory)
            uncertainKey = nil
            needsVerification = false
            message = "You can select the notebook and retry."
        } catch {
            message = "Could not update upload status: \(error.localizedDescription)"
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

struct NotebookUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var upload: NotebookUpload
    @State private var selected = ""

    init(recordingID: String, transcriptURL: URL, dataDirectory: URL) {
        _upload = StateObject(wrappedValue: NotebookUpload(recordingID: recordingID, transcriptURL: transcriptURL, dataDirectory: dataDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload to NotebookLM").font(.title2.weight(.semibold))
            Text(upload.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !upload.choices.isEmpty {
                Picker("Notebook", selection: $selected) {
                    Text("Select a notebook").tag("")
                    ForEach(upload.choices) { choice in Text(choice.title).tag(choice.name) }
                }
                HStack {
                    if upload.needsVerification {
                        Button("Open NotebookLM") {
                            if let url = URL(string: "https://notebook.google.com/") { NSWorkspace.shared.open(url) }
                        }
                        Button("I checked; allow retry") { upload.allowRetryAfterVerification() }
                    }
                    Spacer()
                    Button("Upload") {
                        if let choice = upload.choices.first(where: { $0.name == selected }) { upload.upload(choice) }
                    }.disabled(selected.isEmpty || upload.busy || upload.done || upload.needsVerification)
                }
            } else if !upload.busy && !upload.done {
                if upload.hasSavedClient {
                    Button("Reconnect Google") { upload.reconnect() }
                }
                Button("Choose OAuth client and sign in…") {
                    let panel = NSOpenPanel()
                    panel.message = "Choose the desktop OAuth client JSON downloaded from Google Cloud."
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { upload.start(clientURL: url) }
                }
            }
            if upload.busy { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button(upload.done ? "Done" : "Close") { upload.cancel(); dismiss() }
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { upload.startSaved() }
        .onDisappear { upload.cancel() }
    }
}
