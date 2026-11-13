import AppKit
import SwiftUI

struct NotebookSettingsView: View {
    let dataDirectory: URL
    private var credentialStore: NotebookCredentialStore { NotebookCredentialStore(dataDirectory: dataDirectory) }
    @State private var connected = false
    @State private var busy = false
    @State private var message = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        GroupBox("NotebookLM") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(connected ? "Google authorization saved" : "Not connected")
                    Spacer()
                    if connected {
                        Button("Disconnect") {
                            do {
                                try credentialStore.clear()
                                connected = false
                                message = "Credentials removed from this Mac. Google account access can also be revoked in Google settings."
                            } catch { message = error.localizedDescription }
                        }.disabled(busy)
                    }
                    if connected {
                        Button("Reconnect") { reconnect() }.disabled(busy)
                    }
                    Button(connected ? "Change OAuth Client…" : "Connect…") { chooseClient() }.disabled(busy)
                }
                Text("Credentials are stored in the data folder with access limited to your macOS user. They are not encrypted and may be included in backups. Changing data folders requires connecting again.")
                    .font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.small) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .onAppear { updateState() }
        .onDisappear { task?.cancel() }
        .onChange(of: dataDirectory) { _ in
            task?.cancel()
            busy = false
            connected = false
            message = ""
            updateState()
        }
    }

    private func updateState() {
        do { connected = try credentialStore.load() != nil }
        catch { message = error.localizedDescription }
    }

    private func reconnect() {
        do {
            guard let credential = try credentialStore.load() else {
                message = "No saved authorization. Choose your OAuth client to connect."
                return
            }
            connect(config: credential.config)
        } catch { message = error.localizedDescription }
    }

    private func chooseClient() {
        let panel = NSOpenPanel()
        panel.message = "Choose the desktop OAuth client JSON downloaded from Google Cloud."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try NotebookClientConfig.load(url)
            connect(config: config)
        } catch { message = error.localizedDescription }
    }

    private func connect(config: NotebookClientConfig) {
        let api = NotebookAPI(config: config, credentialStore: credentialStore)
        busy = true
        message = "Complete Google sign-in and authorization in your browser."
        task = Task {
            do {
                try await api.login()
                guard !Task.isCancelled else { return }
                connected = true
                message = "NotebookLM connected."
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
