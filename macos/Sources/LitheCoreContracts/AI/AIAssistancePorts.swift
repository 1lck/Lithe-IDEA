import Foundation

@MainActor
public protocol AICommitMessageGenerating: AnyObject {
    func generateCommitMessage(
        input: CommitMessageInput,
        settings: CommitMessageAISettings
    ) async throws -> String
}

@MainActor
public protocol AIPullRequestDescriptionGenerating: AnyObject {
    func generatePullRequestDescription(
        input: PullRequestDescriptionInput,
        settings: CommitMessageAISettings
    ) async throws -> PullRequestDescriptionOutput
}

public protocol AIProviderCredentialResolver: Sendable {
    func readAPIKey(for provider: AIProviderProfile) -> String?
}

public protocol AIHTTPTransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
}

public struct AIHTTPRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    public let timeout: TimeInterval
    public let allowsInsecureHTTP: Bool

    public init(
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

public struct AIHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol AIConfigurationSource: Sendable {
    func load() -> AIConfigurationSnapshot?
}

public protocol CodexConfigurationSource: AIConfigurationSource {}
public protocol ClaudeConfigurationSource: AIConfigurationSource {}

public enum CommitMessageGenerationError: LocalizedError, Sendable {
    case noProviderConfigured
    case invalidProvider
    case insecureEndpoint
    case missingAPIKey
    case emptyDiff
    case sensitiveFileExcluded
    case httpFailure(statusCode: Int)
    case invalidResponse
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return String(localized: "Configure an AI provider in Settings first.")
        case .invalidProvider:
            return String(localized: "The selected AI provider has an invalid API URL or model.")
        case .insecureEndpoint:
            return String(localized: "HTTP is disabled for this provider. Enable the insecure HTTP option or use HTTPS.")
        case .missingAPIKey:
            return String(localized: "The selected AI provider has no API key.")
        case .emptyDiff:
            return String(localized: "The staged changes have no textual diff to summarize.")
        case .sensitiveFileExcluded:
            return String(localized: "Sensitive files are not sent to an AI provider.")
        case .httpFailure(let statusCode):
            return "\(String(localized: "The AI provider returned an HTTP error.")) (\(statusCode))"
        case .invalidResponse:
            return String(localized: "The AI provider returned an unexpected response.")
        case .emptyResponse:
            return String(localized: "The AI provider returned an empty commit message.")
        }
    }
}
