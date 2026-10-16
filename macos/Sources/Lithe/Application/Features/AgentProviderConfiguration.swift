import Foundation
import LitheCoreContracts

/// An editor draft has no persistence side effects until the user saves it.
struct AgentProviderDraft: Identifiable {
    let id = UUID()
    var providerID: UUID?
    var source: AIConfigurationSourceKind
    var name: String = ""
    var endpoint: String = ""
    var model: String = ""
    var apiKey: String = ""
    var configuration: String
    var authentication: String
    var allowsInsecureHTTP = false
    var isEditingConfigurationText = false
}

/// Coordinates metadata persistence and secure credentials without altering CLI files.
@MainActor
struct AgentProviderConfiguration {
    let settings: AppSettings
    let secureStore: any SecureStore
    let parser: any AgentProviderConfigurationParsing

    func draft(source: AIConfigurationSourceKind, provider: AIProviderProfile? = nil) throws -> AgentProviderDraft {
        let endpoint = provider?.endpoint ?? ""
        let model = provider?.model ?? source.newProviderModel
        let key = provider.flatMap { secureStore.read(key: $0.apiKeyIdentifier) } ?? ""
        var draft = AgentProviderDraft(providerID: provider?.id, source: source, name: provider?.name ?? "",
            endpoint: endpoint, model: model, apiKey: key, configuration: "", authentication: "",
            allowsInsecureHTTP: provider?.allowsInsecureHTTP ?? false)
        let text = try configurationText(for: draft)
        draft.configuration = text.configuration
        draft.authentication = text.authentication
        return draft
    }

    /// Switch the active input once, so hidden fields never overwrite configuration text.
    func setConfigurationTextEditing(_ enabled: Bool, draft: inout AgentProviderDraft) throws {
        guard enabled != draft.isEditingConfigurationText else { return }
        if enabled {
            let text = try configurationText(for: draft)
            draft.configuration = text.configuration
            draft.authentication = text.authentication
        } else {
            // Parse before changing the draft: invalid pasted text remains available to correct.
            let snapshot = try parser.parse(source: draft.source, configuration: draft.configuration,
                authentication: draft.authentication, allowIncomplete: true)
            let expected: CommitMessageAPIProtocol = draft.source == .codex ? .responses : .anthropicMessages
            guard snapshot.apiProtocol == expected else { throw AgentProviderConfigurationError.unsupportedProtocol }
            draft.endpoint = snapshot.endpoint
            draft.model = snapshot.model
            draft.apiKey = snapshot.apiKey ?? ""
        }
        draft.isEditingConfigurationText = enabled
    }

    private func configurationText(for draft: AgentProviderDraft) throws -> (configuration: String, authentication: String) {
        switch draft.source {
        case .codex:
            let configuration = """
            model = \(try quoted(draft.model.trimmingCharacters(in: .whitespacesAndNewlines)))
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            base_url = \(try quoted(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)))
            wire_api = "responses"
            requires_openai_auth = true
            """
            return (configuration, try json(["OPENAI_API_KEY": draft.apiKey]))
        case .claude:
            return (try json(["env": ["ANTHROPIC_BASE_URL": draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                "ANTHROPIC_MODEL": draft.model.trimmingCharacters(in: .whitespacesAndNewlines), "ANTHROPIC_API_KEY": draft.apiKey]]), "")
        }
    }

    /// Validate before stopping a connection or changing saved state.
    func validate(_ draft: AgentProviderDraft) throws -> (AIProviderProfile, String) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentProviderConfigurationError.invalidName }
        let snapshot = try configurationSnapshot(for: draft)
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

    private func configurationSnapshot(for draft: AgentProviderDraft) throws -> AIConfigurationSnapshot {
        let text: (configuration: String, authentication: String)
        if draft.isEditingConfigurationText {
            text = (draft.configuration, draft.authentication)
        } else {
            // CLI parsing may supply defaults; an explicit form must require the user's values.
            guard !draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentProviderConfigurationError.invalidEndpoint
            }
            guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentProviderConfigurationError.missingModel
            }
            guard !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentProviderConfigurationError.missingAPIKey
            }
            text = try configurationText(for: draft)
        }
        let snapshot = try parser.parse(source: draft.source, configuration: text.configuration, authentication: text.authentication)
        let expected: CommitMessageAPIProtocol = draft.source == .codex ? .responses : .anthropicMessages
        guard snapshot.apiProtocol == expected else { throw AgentProviderConfigurationError.unsupportedProtocol }
        return snapshot
    }

    func save(_ provider: AIProviderProfile, key: String, replacing previous: AIProviderProfile?) throws {
        // Another project can change the shared registry while its peer awaits process exit.
        // Check immediately before credential mutation, with no suspension before publication.
        let current = settings.commitMessageAI.providers.first { $0.id == provider.id }
        guard current == previous else { throw AgentProviderConfigurationError.invalidConfiguration }
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
