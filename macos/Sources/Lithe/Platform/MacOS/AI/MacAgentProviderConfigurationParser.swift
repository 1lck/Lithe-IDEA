import Foundation
import LitheCoreContracts

/// Shared TOML/JSON metadata parsing plus native, ephemeral credential extraction.
struct MacAgentProviderConfigurationParser: AgentProviderConfigurationParsing {
    let core: RustCoreBridge

    private struct Payload: Encodable {
        let source: String
        let configuration: String
    }
    private struct Metadata: Decodable {
        let name: String
        let endpoint: String
        let model: String
        let apiProtocol: CommitMessageAPIProtocol
        let authentication: AIProviderAuthentication
    }

    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String) throws -> AIConfigurationSnapshot {
        guard configuration.utf8.count <= 64 * 1024, authentication.utf8.count <= 64 * 1024 else {
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        let metadata: Metadata
        do {
            metadata = try core.executeResult(command: "agent.parseProviderConfiguration", payload: Payload(
                source: source.rawValue, configuration: configuration
            )).get()
        } catch {
            // Never present parser details, which could quote a pasted credential.
            if source == .codex, configuration.contains("“") || configuration.contains("”") {
                throw AgentProviderConfigurationError.invalidConfigurationQuotes
            }
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        let key: String?
        switch source {
        case .codex:
            guard let object = try? JSONSerialization.jsonObject(with: Data(authentication.utf8)) as? [String: Any],
                  let value = (object["OPENAI_API_KEY"] ?? object["api_key"]) as? String else {
                throw AgentProviderConfigurationError.invalidAuthentication
            }
            key = value
        case .claude:
            let snapshot = MacClaudeConfigurationParser.parse(settingsData: Data(configuration.utf8),
                credentialsData: nil, rootConfigData: nil, environment: [:])
            guard snapshot?.hasAPIKey == true else { throw AgentProviderConfigurationError.missingAPIKey }
            guard snapshot?.authentication == .apiKey else { throw AgentProviderConfigurationError.unsupportedProtocol }
            key = snapshot?.apiKey
        }
        return AIConfigurationSnapshot(source: source, providerName: metadata.name, endpoint: metadata.endpoint,
            model: metadata.model, apiProtocol: metadata.apiProtocol, authentication: metadata.authentication,
            reasoningEffort: nil, requiresAPIKey: true, apiKey: key)
    }
}
