import Foundation
import LitheCoreContracts

/// An editor draft has no persistence side effects until the user saves it.
struct AgentProviderDraft: Identifiable {
    let id = UUID()
    var providerID: UUID?
    var source: AIConfigurationSourceKind
    var name: String = ""
    var configuration: String
    var authentication: String
    var allowsInsecureHTTP = false
}

/// Coordinates metadata persistence and secure credentials without altering CLI files.
@MainActor
struct AgentProviderConfiguration {
    let settings: AppSettings
    let secureStore: any SecureStore
    let parser: any AgentProviderConfigurationParsing

    func draft(source: AIConfigurationSourceKind, provider: AIProviderProfile? = nil) throws -> AgentProviderDraft {
        let endpoint = provider?.endpoint ?? ""
        let model = provider?.model ?? ""
        let key = provider.flatMap { secureStore.read(key: $0.apiKeyIdentifier) } ?? ""
        let configuration: String
        let authentication: String
        switch source {
        case .codex:
            configuration = """
            model = \(try quoted(model))
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            base_url = \(try quoted(endpoint))
            wire_api = "responses"
            requires_openai_auth = true
            """
            authentication = try json(["OPENAI_API_KEY": key])
        case .claude:
            configuration = try json(["env": ["ANTHROPIC_BASE_URL": endpoint,
                "ANTHROPIC_MODEL": model, "ANTHROPIC_API_KEY": key]])
            authentication = ""
        }
        return AgentProviderDraft(providerID: provider?.id, source: source, name: provider?.name ?? "",
            configuration: configuration, authentication: authentication,
            allowsInsecureHTTP: provider?.allowsInsecureHTTP ?? false)
    }

    /// Validate before stopping a connection or changing saved state.
    func validate(_ draft: AgentProviderDraft) throws -> (AIProviderProfile, String) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentProviderConfigurationError.invalidName }
        let snapshot = try parser.parse(source: draft.source, configuration: draft.configuration, authentication: draft.authentication)
        let expected: CommitMessageAPIProtocol = draft.source == .codex ? .responses : .anthropicMessages
        guard snapshot.apiProtocol == expected else { throw AgentProviderConfigurationError.unsupportedProtocol }
        let existing = draft.providerID.flatMap { id in settings.commitMessageAI.providers.first { $0.id == id } }
        // Imported profiles stay linked to their CLI; stale editor drafts cannot recreate deleted profiles.
        guard draft.providerID == nil || existing?.credentialSource == .local else {
            throw AgentProviderConfigurationError.invalidConfiguration
        }
        let provider = AIProviderProfile(id: existing?.id ?? UUID(), name: name,
            endpoint: snapshot.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), model: snapshot.model,
            apiProtocol: snapshot.apiProtocol, authentication: snapshot.authentication,
            allowsInsecureHTTP: draft.allowsInsecureHTTP, apiKeyIdentifier: existing?.apiKeyIdentifier)
        guard provider.isValid, let url = provider.endpointURL,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AgentProviderConfigurationError.invalidEndpoint
        }
        guard url.scheme?.lowercased() != "http" || draft.allowsInsecureHTTP else {
            throw AgentProviderConfigurationError.insecureHTTP
        }
        let key = snapshot.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw AgentProviderConfigurationError.missingAPIKey }
        return (provider, key)
    }

    func save(_ provider: AIProviderProfile, key: String) throws {
        // A failed credential write must not leave an apparently usable provider in settings.
        try secureStore.write(key, key: provider.apiKeyIdentifier)
        var value = settings.commitMessageAI
        if let index = value.providers.firstIndex(where: { $0.id == provider.id }) {
            value.providers[index] = provider
        } else {
            value.providers.append(provider)
        }
        value.codexImportCompleted = true
        settings.commitMessageAI = value
    }

    func remove(_ provider: AIProviderProfile) throws {
        guard provider.credentialSource == .local else { throw AgentProviderConfigurationError.invalidConfiguration }
        // Failed deletion keeps the profile available for retry instead of orphaning its credential.
        try secureStore.delete(key: provider.apiKeyIdentifier)
        settings.removeAIProvider(provider.id)
    }

    private func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
