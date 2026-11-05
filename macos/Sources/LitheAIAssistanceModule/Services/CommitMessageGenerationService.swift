import Foundation
import LitheCoreContracts

public struct CommitMessageGenerationService: Sendable {
    private let core: any AICommitPlanning
    private let transport: any AIHTTPTransport
    private let credentialResolver: any AIProviderCredentialResolver

    public init(
        core: any AICommitPlanning,
        transport: any AIHTTPTransport,
        credentialResolver: any AIProviderCredentialResolver
    ) {
        self.core = core
        self.transport = transport
        self.credentialResolver = credentialResolver
    }

    public func generate(
        input: CommitMessageInput,
        settings: CommitMessageAISettings
    ) async throws -> String {
        try Task.checkCancellation()
        guard let provider = settings.activeProvider else {
            throw CommitMessageGenerationError.noProviderConfigured
        }
        let plan = try core.planCommit(input: input, settings: settings, provider: provider)
        try Task.checkCancellation()
        let apiKey = try credential(for: provider)
        let response = try await send(provider: provider, url: plan.url, body: plan.body, apiKey: apiKey)
        return try core.decodeCommitResponse(
            protocolName: provider.apiProtocol, response: response.body, includeBody: settings.includeBody
        )
    }

    public func generatePullRequestDescription(
        input: PullRequestDescriptionInput,
        settings: CommitMessageAISettings
    ) async throws -> PullRequestDescriptionOutput {
        try Task.checkCancellation()
        guard let provider = settings.activeProvider else {
            throw CommitMessageGenerationError.noProviderConfigured
        }
        let plan = try core.planPullRequest(input: input, settings: settings, provider: provider)
        try Task.checkCancellation()
        let apiKey = try credential(for: provider)
        let response = try await send(provider: provider, url: plan.url, body: plan.body, apiKey: apiKey)
        return try core.decodePullRequestResponse(protocolName: provider.apiProtocol, response: response.body)
    }

    private func credential(for provider: AIProviderProfile) throws -> String? {
        let apiKey = credentialResolver.readAPIKey(for: provider)
        if provider.requiresAPIKey,
           apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw CommitMessageGenerationError.missingAPIKey
        }
        return apiKey
    }

    private func send(provider: AIProviderProfile, url: URL, body: Data, apiKey: String?) async throws -> AIHTTPResponse {
        try Task.checkCancellation()
        var headers = ["Accept": "application/json", "Content-Type": "application/json"]
        if let apiKey, !apiKey.isEmpty {
            if provider.authentication == .apiKey {
                headers["x-api-key"] = apiKey
            } else {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
        }
        if provider.apiProtocol == .anthropicMessages {
            headers["anthropic-version"] = "2023-06-01"
        }
        let response = try await transport.send(AIHTTPRequest(
            url: url, headers: headers, body: body, timeout: 45,
            allowsInsecureHTTP: provider.allowsInsecureHTTP
        ))
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw CommitMessageGenerationError.httpFailure(statusCode: response.statusCode)
        }
        return response
    }
}
