import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    var isAgentConversationEnabled: Bool {
        guard let snapshot = try? services.moduleRuntime.snapshot(for: .agentConversation) else { return false }
        return snapshot.state != .disabled
    }

    var agentConversationFeatureIfActive: AgentConversationFeatureModel? {
        (services.moduleRuntime.capability(.agentConversation) as? AgentConversationCapability)?.feature
    }

    func setAgentConversationEnabled(_ enabled: Bool) async {
        if !enabled {
            workbenchFeature.setVisibility(.agent, isVisible: false)
            agentConversationNeedsAttention = false
        }
        do {
            try await services.moduleRuntime.setEnabled(enabled, for: .agentConversation)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
        }
    }

    func toggleAgentConversation() {
        guard workspaceURL != nil else { return }
        guard toggleToolWindow(.agent) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await awaitModuleRuntimeShutdown()
                _ = try await services.moduleRuntime.activateCapability(.agentConversation)
                objectWillChange.send()
                connectAgentConversation()
            } catch {
                workbenchFeature.setVisibility(.agent, isVisible: false)
                showNotification(error.localizedDescription)
            }
        }
    }

    /// Directory holding Lithe-managed ACP adapter installs.
    var agentDataDirectory: URL {
        services.fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
    }

    /// Agents with a provider assigned in Settings › Agents, for the panel.
    var configuredAgentOptions: [AgentOption] {
        settings.agentConfigurations
            .filter { id, configuration in
                configuration.providerID != nil
                    && (id != AgentConfiguration.customAgentID
                        || !settings.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .map { AgentOption(id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Refresh the panel's agents and start the selected one if needed.
    func connectAgentConversation() {
        guard let feature = agentConversationFeatureIfActive else { return }
        feature.onAttentionChanged = { [weak self] needsAttention in
            self?.agentConversationNeedsAttention = needsAttention
        }
        feature.setAgents(configuredAgentOptions)
        guard let agentID = feature.selectedAgentID else { return }
        let connection = feature.connection(for: agentID)
        guard !connection.hasActiveConnection else { return }
        do {
            try connection.connect(configuration: agentLaunchConfiguration(agentID: agentID))
        } catch {
            // The panel shows the reason and offers a retry.
            connection.reportConnectionFailure(error.localizedDescription)
        }
    }

    func selectAgentConversationAgent(_ agentID: String) {
        agentConversationFeatureIfActive?.selectAgent(agentID)
        connectAgentConversation()
    }

    func agentLaunchConfiguration(agentID: String) throws -> AgentLaunchConfiguration {
        guard let workspaceURL else { throw AgentConversationError.notConnected }
        guard let provider = settings.agentProvider(for: agentID) else {
            throw AgentConversationError.missingProvider
        }
        let apiKey = services.credentialResolver.readAPIKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw AgentConversationError.missingAPIKey }
        let isCustom = agentID == AgentConfiguration.customAgentID
        let command = settings.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCustom && command.isEmpty { throw AgentConversationError.missingCommand }
        // One argument per line, passed to the process without shell parsing.
        let arguments = isCustom
            ? settings.agentArguments
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            : []
        return AgentLaunchConfiguration(
            agentID: isCustom ? nil : agentID,
            command: command,
            arguments: arguments,
            workspaceURL: workspaceURL,
            dataDirectory: agentDataDirectory,
            providerProtocol: provider.apiProtocol.rawValue,
            providerEndpoint: provider.endpoint,
            apiKey: apiKey,
            providerName: provider.name,
            model: provider.model,
            allowsInsecureHTTP: provider.allowsInsecureHTTP
        )
    }
}
