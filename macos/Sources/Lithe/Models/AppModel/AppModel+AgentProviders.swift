import Foundation
import LitheCoreContracts
import LitheAgentConversationModule

extension AppModel {
    private var agentProviderConfiguration: AgentProviderConfiguration {
        AgentProviderConfiguration(settings: settings, secureStore: services.secureStore,
            parser: services.agentProviderConfigurationParser)
    }

    func agentProviderDraft(source: AIConfigurationSourceKind, provider: AIProviderProfile? = nil) throws -> AgentProviderDraft {
        try agentProviderConfiguration.draft(source: source, provider: provider)
    }

    func saveAgentProvider(_ draft: AgentProviderDraft) async throws {
        try beginAgentProviderChange()
        defer { finishAgentProviderChange() }
        let (provider, key) = try agentProviderConfiguration.validate(draft)
        let affected = settings.agentConfigurations.filter { $0.value.providerID == provider.id }.map(\.key)
        try await stopAgentsForProviderChange(affected)
        try agentProviderConfiguration.save(provider, key: key)
        if !affected.isEmpty { connectAgentConversation() }
    }

    func deleteAgentProvider(_ provider: AIProviderProfile) async throws {
        try beginAgentProviderChange()
        defer { finishAgentProviderChange() }
        let affected = settings.agentConfigurations.filter { $0.value.providerID == provider.id }.map(\.key)
        try await stopAgentsForProviderChange(affected)
        try agentProviderConfiguration.remove(provider)
        agentConversationFeatureIfActive?.setAgents(configuredAgentOptions)
        connectAgentConversation()
    }

    func useAgentProvider(_ provider: AIProviderProfile?, agentID: String, name: String) async throws {
        try beginAgentProviderChange()
        defer { finishAgentProviderChange() }
        if let provider {
            guard settings.commitMessageAI.providers.contains(where: { $0.id == provider.id }), provider.isValid else {
                throw AgentProviderConfigurationError.invalidConfiguration
            }
        }
        try await stopAgentsForProviderChange([agentID])
        settings.setAgentProvider(provider?.id, for: agentID, name: name)
        agentConversationFeatureIfActive?.setAgents(configuredAgentOptions)
        if provider != nil { agentConversationFeatureIfActive?.selectAgent(agentID) }
        connectAgentConversation()
    }

    func useLocalAgentProvider(source: AIConfigurationSourceKind, agentID: String, name: String) async throws {
        try beginAgentProviderChange()
        defer { finishAgentProviderChange() }
        // Discover before stopping: a missing local configuration must preserve the current connection.
        guard loadAIConfigurations().contains(where: { $0.source == source }) else {
            throw AgentConversationError.missingProvider
        }
        try await stopAgentsForProviderChange([agentID])
        if importLocalConfiguration(for: agentID, source: source, name: name) {
            agentConversationFeatureIfActive?.setAgents(configuredAgentOptions)
            agentConversationFeatureIfActive?.selectAgent(agentID)
            connectAgentConversation()
        }
    }

    private func stopAgentsForProviderChange(_ agentIDs: [String]) async throws {
        try Task.checkCancellation()
        guard let feature = agentConversationFeatureIfActive else { return }
        let connections = agentIDs.sorted().map { feature.connection(for: $0) }
        guard connections.allSatisfy({ connection in
            !connection.isCreatingSession && connection.connectionState != .connecting &&
                !connection.conversations.values.contains {
                    $0.isResponding || $0.isLoading || $0.pendingConfigToken != nil || $0.permission != nil
                }
        }) else { throw AgentProviderConfigurationError.busy }
        for connection in connections { await connection.stop() }
        try Task.checkCancellation()
    }

    private func beginAgentProviderChange() throws {
        try Task.checkCancellation()
        guard !isChangingAgentProvider else { throw AgentProviderConfigurationError.busy }
        isChangingAgentProvider = true
    }

    private func finishAgentProviderChange() {
        isChangingAgentProvider = false
        // Restore the old profile after a storage failure, or connect using the saved selection.
        connectAgentConversation()
    }
}
