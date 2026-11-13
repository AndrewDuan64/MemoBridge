import Foundation

private final class MockGoogle: URLProtocol {
    static var seenRefresh = false
    static var seenAuthenticatedRequest = false
    static var tokenStatus = 200
    static var tokenPayload = #"{"access_token":"test-access","expires_in":3600}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        if url.host == "oauth2.googleapis.com" {
            var requestBody = request.httpBody ?? Data()
            if requestBody.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    requestBody.append(contentsOf: buffer.prefix(count))
                }
            }
            let submitted = String(data: requestBody, encoding: .utf8) ?? ""
            Self.seenRefresh = submitted.contains("grant_type=refresh_token") && submitted.contains("refresh_token=test-refresh")
            body = Data(Self.tokenPayload.utf8)
        } else if url.host == "notebook.googleapis.com" {
            Self.seenAuthenticatedRequest = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access"
                && request.value(forHTTPHeaderField: "x-goog-user-project") == "test-project"
            body = Data(#"{"notebooks":[{"name":"notebooks/test-id","displayName":"Test"}]}"#.utf8)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let status = url.host == "oauth2.googleapis.com" ? Self.tokenStatus : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct NotebookAuthorizationTests {
    static func main() async throws {
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MemoBridge-auth-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let firstStore = NotebookCredentialStore(dataDirectory: testDirectory.appendingPathComponent("first"))
        let secondStore = NotebookCredentialStore(dataDirectory: testDirectory.appendingPathComponent("second"))
        let testClient = NotebookClientConfig(clientID: "test-client", clientSecret: "test-secret", projectID: "test-project")
        try firstStore.save(NotebookCredential(config: testClient, refreshToken: "test-refresh"))
        guard try firstStore.load()?.refreshToken == "test-refresh", try secondStore.load() == nil else {
            throw NotebookError.message("Credentials were not isolated by data directory.")
        }
        let directory = testDirectory.appendingPathComponent("first/.credentials")
        let file = directory.appendingPathComponent("notebooklm.json")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        guard directoryMode == 0o700, fileMode == 0o600 else {
            throw NotebookError.message("Credential permissions are not private.")
        }
        try firstStore.clear()
        guard try firstStore.load() == nil else { throw NotebookError.message("Credentials were not removed.") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoogle.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = NotebookClientConfig(clientID: "test-client", clientSecret: "test-secret", projectID: "test-project")
        let api = NotebookAPI(config: client, session: session)
        try await api.restore(NotebookCredential(config: client, refreshToken: "test-refresh"))
        let notebooks = try await api.notebooks()
        guard MockGoogle.seenRefresh, MockGoogle.seenAuthenticatedRequest,
              notebooks.count == 1, notebooks[0].name == "notebooks/test-id" else {
            throw NotebookError.message("Offline test failed (refresh: \(MockGoogle.seenRefresh), authenticated: \(MockGoogle.seenAuthenticatedRequest), notebooks: \(notebooks.count)).")
        }
        MockGoogle.tokenStatus = 400
        MockGoogle.tokenPayload = #"{"error":"invalid_grant"}"#
        do {
            try await api.restore(NotebookCredential(config: client, refreshToken: "test-refresh"))
            throw NotebookError.message("Revoked credentials unexpectedly succeeded.")
        } catch {
            guard error.localizedDescription.contains("expired or was revoked") else { throw error }
        }
        MockGoogle.tokenStatus = 429
        MockGoogle.tokenPayload = #"{"error":"rate_limited"}"#
        do {
            try await api.restore(NotebookCredential(config: client, refreshToken: "test-refresh"))
            throw NotebookError.message("A rate limit unexpectedly succeeded.")
        } catch {
            guard error.localizedDescription.contains("HTTP 429") else { throw error }
        }
        print("NotebookLM: private credential storage, refresh token and authenticated request verified without network")
    }
}
