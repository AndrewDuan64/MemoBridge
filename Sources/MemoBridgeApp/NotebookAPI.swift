import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct NotebookClientConfig: Codable {
    let clientID: String
    let clientSecret: String
    let projectID: String

    static func load(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let installed = object?["installed"] as? [String: Any],
              let clientID = installed["client_id"] as? String, !clientID.isEmpty,
              let projectID = installed["project_id"] as? String, !projectID.isEmpty else {
            throw NotebookError.message("Choose the desktop OAuth client JSON downloaded from Google Cloud.")
        }
        return Self(clientID: clientID, clientSecret: installed["client_secret"] as? String ?? "", projectID: projectID)
    }
}

enum NotebookError: LocalizedError {
    case message(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .httpStatus(let status): return "NotebookLM returned HTTP \(status). Check your account, API access, and authorization."
        }
    }
}

struct NotebookChoice: Identifiable, Decodable {
    let name: String
    let displayName: String?
    var id: String { name }
    var title: String { displayName?.isEmpty == false ? displayName! : "Untitled notebook" }
}

private struct NotebookList: Decodable {
    let notebooks: [NotebookChoice]?
    let nextPageToken: String?
}

struct NotebookSource: Decodable {
    let name: String?
    let state: String?
    let error: SourceError?
    struct SourceError: Decodable { let message: String? }
}

private struct OAuthToken: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
    }
}

struct NotebookCredential: Codable {
    let config: NotebookClientConfig
    let refreshToken: String
}

/// OAuth credentials are stored in a private folder inside the selected data directory.
struct NotebookCredentialStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("notebooklm.json") }

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent(".credentials", isDirectory: true)
    }

    func load() throws -> NotebookCredential? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode(NotebookCredential.self, from: Data(contentsOf: file))
        } catch {
            throw NotebookError.message("Unable to read saved NotebookLM credentials. Reconnect in Settings.")
        }
    }

    func save(_ credential: NotebookCredential) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // Restrict existing directories too. Atomic writes stay inside this private directory.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(credential)
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw NotebookError.message("Unable to save NotebookLM credentials in the data folder. Check folder permissions.")
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { throw NotebookError.message("Unable to remove saved NotebookLM credentials from the data folder.") }
    }
}

private func randomURLSafe(_ count: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw NotebookError.message("Unable to generate secure authorization data.")
    }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func formEncoded(_ values: [String: String]) -> Data {
    // URLComponents keeps '+' in query values, but form decoders interpret it as a space.
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    let form = values.map { encode($0.key) + "=" + encode($0.value) }.sorted().joined(separator: "&")
    return Data(form.utf8)
}

/// A one-shot loopback receiver. The state and code never enter application logs or files.
final class OAuthReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MemoBridge.oauth.loopback")
    private var listener: NWListener?
    private var finish: ((Result<(String, String), Error>) -> Void)?
    private var completed = false

    func start(config: NotebookClientConfig, verifier: String, state: String) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.completed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.finish = { continuation.resume(with: $0) }
                do {
                    let params = NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: params)
                    self.listener = listener
                    listener.stateUpdateHandler = { status in
                        switch status {
                        case .ready:
                            guard let port = listener.port?.rawValue else {
                                self.complete(.failure(NotebookError.message("Unable to start the local authorization callback."))); return
                            }
                            let redirect = "http://127.0.0.1:\(port)/callback"
                            let digest = SHA256.hash(data: Data(verifier.utf8))
                            let challenge = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                            components.queryItems = [
                                URLQueryItem(name: "client_id", value: config.clientID),
                                URLQueryItem(name: "redirect_uri", value: redirect),
                                URLQueryItem(name: "response_type", value: "code"),
                                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/notebook"),
                                URLQueryItem(name: "access_type", value: "offline"),
                                URLQueryItem(name: "prompt", value: "consent"),
                                URLQueryItem(name: "state", value: state),
                                URLQueryItem(name: "code_challenge", value: challenge),
                                URLQueryItem(name: "code_challenge_method", value: "S256")
                            ]
                            guard let url = components.url else {
                                self.complete(.failure(NotebookError.message("Unable to create the authorization URL."))); return
                            }
                            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                        case .failed(let error):
                            self.complete(.failure(NotebookError.message("Unable to start the local authorization callback: \(error.localizedDescription)")))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        connection.start(queue: self.queue)
                        self.read(connection, data: Data(), state: state, redirect: { port in
                            "http://127.0.0.1:\(port)/callback"
                        })
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 300) {
                        self.complete(.failure(NotebookError.message("Google authorization timed out. Please try again.")))
                    }
                } catch {
                    self.complete(.failure(NotebookError.message("Unable to start the local authorization callback: \(error.localizedDescription)")))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.complete(.failure(NotebookError.message("Authorization cancelled."))) }
    }

    private func complete(_ result: Result<(String, String), Error>) {
        guard !completed else { return }
        completed = true
        listener?.cancel()
        listener = nil
        let callback = finish
        finish = nil
        callback?(result)
    }

    private func read(_ connection: NWConnection, data: Data, state: String, redirect: @escaping (UInt16) -> String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, _ in
            var received = data
            if let chunk { received.append(chunk) }
            guard received.count <= 16384 else { connection.cancel(); return }
            guard let text = String(data: received, encoding: .utf8), text.contains("\r\n\r\n") else {
                if isComplete { connection.cancel() } else { self.read(connection, data: received, state: state, redirect: redirect) }
                return
            }
            let request = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            guard request.count >= 2, request[0] == "GET",
                  let url = URLComponents(string: "http://127.0.0.1" + String(request[1])), url.path == "/callback",
                  url.queryItems?.first(where: { $0.name == "state" })?.value == state else {
                self.reply(connection, message: "Invalid authorization response.", status: "400 Bad Request")
                return
            }
            if let error = url.queryItems?.first(where: { $0.name == "error" })?.value {
                self.reply(connection, message: "Authorization not completed. Return to MemoBridge.", status: "200 OK")
                self.complete(.failure(NotebookError.message("Google authorization was not completed: \(error)")))
            } else if let code = url.queryItems?.first(where: { $0.name == "code" })?.value,
                      let port = self.listener?.port?.rawValue {
                self.reply(connection, message: "Authorization received. Return to MemoBridge.", status: "200 OK")
                self.complete(.success((code, redirect(port))))
            } else {
                self.reply(connection, message: "Invalid authorization response.", status: "400 Bad Request")
            }
        }
    }

    private func reply(_ connection: NWConnection, message: String, status: String) {
        let body = Data(message.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class NotebookAPI {
    private let config: NotebookClientConfig
    private let session: URLSession
    private let credentialStore: NotebookCredentialStore?
    private var accessToken: String?
    private var credential: NotebookCredential?
    private var expiresAt: Date?
    private let base = URL(string: "https://notebook.googleapis.com/v1/")!

    init(config: NotebookClientConfig, credentialStore: NotebookCredentialStore? = nil, session: URLSession = .shared) {
        self.config = config
        self.credentialStore = credentialStore
        self.session = session
    }

    func login() async throws {
        try Task.checkCancellation()
        let verifier = try randomURLSafe(48)
        let state = try randomURLSafe(32)
        let receiver = OAuthReceiver()
        let (code, redirect) = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await receiver.start(config: config, verifier: verifier, state: state)
        }, onCancel: {
            receiver.cancel()
        })
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            "code": code, "client_id": config.clientID, "client_secret": config.clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw NotebookError.message("Google authorization failed. Check the desktop OAuth client, test user, and Notebook API configuration.")
        }
        let token = try JSONDecoder().decode(OAuthToken.self, from: data)
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw NotebookError.message("Google did not provide a refresh token. Reconnect and allow offline access.")
        }
        let credential = NotebookCredential(config: config, refreshToken: refreshToken)
        guard let credentialStore else { throw NotebookError.message("No data folder is configured for NotebookLM credentials.") }
        try credentialStore.save(credential)
        self.credential = credential
        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(token.expiresIn ?? 3600)
    }

    func restore(_ credential: NotebookCredential) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(["refresh_token": credential.refreshToken,
                                        "client_id": credential.config.clientID,
                                        "client_secret": credential.config.clientSecret,
                                        "grant_type": "refresh_token"])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotebookError.message("Google returned an invalid authorization response.")
        }
        guard 200..<300 ~= http.statusCode else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if body?["error"] as? String == "invalid_grant" {
                throw NotebookError.message("Google authorization has expired or was revoked. Reconnect NotebookLM in Settings.")
            }
            throw NotebookError.message("Google authorization failed (HTTP \(http.statusCode)). Check your connection and project settings.")
        }
        let token = try JSONDecoder().decode(OAuthToken.self, from: data)
        self.credential = credential
        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(token.expiresIn ?? 3600)
    }

    private func request(path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        if let expiresAt, expiresAt.timeIntervalSinceNow < 60, let credential {
            try await restore(credential)
        }
        guard let token = accessToken else { throw NotebookError.message("Sign in to Google first.") }
        guard let url = URL(string: path, relativeTo: base), var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw NotebookError.message("Invalid notebook address.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url, finalURL.scheme == "https", finalURL.host == "notebook.googleapis.com" else {
            throw NotebookError.message("Invalid notebook address.")
        }
        var request = URLRequest(url: finalURL)
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(config.projectID, forHTTPHeaderField: "x-goog-user-project")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotebookError.message("NotebookLM returned an invalid response.") }
        guard 200..<300 ~= http.statusCode else {
            throw NotebookError.httpStatus(http.statusCode)
        }
        return data
    }

    func notebooks() async throws -> [NotebookChoice] {
        var all: [NotebookChoice] = []
        var page: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let pageData = try await request(path: "notebooks", query: query)
            let result = try JSONDecoder().decode(NotebookList.self, from: pageData)
            all.append(contentsOf: result.notebooks ?? [])
            page = result.nextPageToken
        } while page != nil && page != ""
        return all
    }

    func createSource(notebook: String, text: String) async throws -> NotebookSource {
        guard notebook.range(of: #"^notebooks/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw NotebookError.message("Google returned an invalid notebook ID.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["display_name": "MemoBridge Transcript", "text_content": ["content": text]])
        let data = try await request(path: notebook + "/sources", body: body)
        return try JSONDecoder().decode(NotebookSource.self, from: data)
    }

    func source(name: String) async throws -> NotebookSource {
        guard name.range(of: #"^notebooks/[A-Za-z0-9_-]+/sources/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw NotebookError.message("Google returned an invalid source ID.")
        }
        let data = try await request(path: name)
        return try JSONDecoder().decode(NotebookSource.self, from: data)
    }
}
