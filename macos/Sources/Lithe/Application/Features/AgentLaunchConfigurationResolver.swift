import Foundation
import LitheAgentConversationModule
import LitheCoreContracts

/// Resolves one connection's route and credential together, without changing CLI files.
@MainActor
struct AgentLaunchConfigurationResolver {
    let settings: AppSettings
    let configurationSources: [any AIConfigurationSource]
    let credentialResolver: any AIProviderCredentialResolver

    func resolve(agentID: String, workspaceURL: URL, dataDirectory: URL) throws -> AgentLaunchConfiguration {
        if settings.agentConfigurations[agentID]?.authentication == .codexSubscription {
            guard agentID == "codex-acp" else { throw AgentConversationError.missingProvider }
            return AgentLaunchConfiguration(agentID: agentID, command: "", arguments: [],
                workspaceURL: workspaceURL, dataDirectory: dataDirectory,
                providerProtocol: "", providerEndpoint: "", apiKey: "", providerName: "", model: "",
                allowsInsecureHTTP: false, authentication: .codexSubscription)
        }
        guard var provider = settings.agentProvider(for: agentID) else {
            throw AgentConversationError.missingProvider
        }
        let credential: String?
        if let source = provider.credentialSource.configurationSource {
            // Never combine a saved endpoint with a key from a later CLI read.
            let snapshots = configurationSources.compactMap { $0.load() }
            guard let snapshot = snapshots.first(where: { $0.source == source }) else {
                // Codex can expose a default model without a usable API configuration.
                settings.refreshAgentModels(from: configurationSources.compactMap { $0.loadModel() })
                throw AgentConversationError.missingProvider
            }
            guard let refreshed = settings.refreshImportedAIProvider(provider.id, from: snapshot) else {
                throw AgentConversationError.missingProvider
            }
            provider = refreshed
            credential = snapshot.apiKey
        } else {
            credential = credentialResolver.readAPIKey(for: provider)
        }
        let apiKey = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw AgentConversationError.missingAPIKey }
        let isCustom = agentID == AgentConfiguration.customAgentID
        let command = settings.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCustom && command.isEmpty { throw AgentConversationError.missingCommand }
        // One argument per line, passed to the process without shell parsing.
        let arguments = isCustom
            ? settings.agentArguments.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return AgentLaunchConfiguration(agentID: isCustom ? nil : agentID,
            command: command, arguments: arguments, workspaceURL: workspaceURL, dataDirectory: dataDirectory,
            providerProtocol: provider.apiProtocol.rawValue, providerEndpoint: provider.endpoint,
            apiKey: apiKey, providerName: provider.name, model: provider.model,
            allowsInsecureHTTP: provider.allowsInsecureHTTP)
    }
}
