import Foundation

protocol SecureStore: Sendable {
    func read(key: String) -> String?
    func write(_ value: String, key: String) throws
    func delete(key: String) throws
}

protocol AIProviderCredentialResolver: Sendable {
    func readAPIKey(for provider: AIProviderProfile) -> String?
}

protocol AIHTTPTransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
}

struct AIHTTPRequest: Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
    let timeout: TimeInterval
    let allowsInsecureHTTP: Bool

    init(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval,
        allowsInsecureHTTP: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

struct AIHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol AIConfigurationSource: Sendable {
    func load() -> AIConfigurationSnapshot?
}

protocol CodexConfigurationSource: AIConfigurationSource {
}

protocol ClaudeConfigurationSource: AIConfigurationSource {
}
