import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    func openAgentFile(_ location: AgentToolDetails.Location) {
        guard let workspaceURL, let url = location.fileURL(in: workspaceURL) else {
            showNotification(String(localized: "This file is outside the current project."))
            return
        }
        if let line = location.line {
            navigateToEditorLocation(url: url, line: line - 1, utf16Column: 0)
        } else {
            openFile(url)
        }
    }

    var isAgentConversationEnabled: Bool {
        guard let snapshot = try? services.moduleRuntime.snapshot(for: .agentConversation) else { return false }
        return snapshot.state != .disabled
    }

    var agentConversationFeatureIfActive: AgentConversationFeatureModel? {
        (services.moduleRuntime.capability(.agentConversation) as? AgentConversationCapability)?.feature
    }

    /// The panel stays open when the feature is turned off; only the Agent
    /// processes stop and the panel explains how to turn it back on.
    func setAgentConversationEnabled(_ enabled: Bool) async {
        if !enabled {
            agentConversationNeedsAttention = false
        }
        do {
            try await services.moduleRuntime.setEnabled(enabled, for: .agentConversation)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        if enabled, workbenchFeature.isVisible(.agent) {
            activateAgentConversation()
        }
    }

    /// Show or hide the panel. The panel always renders its full layout; the
    /// module is only activated when the feature is enabled.
    func toggleAgentConversation() {
        guard workspaceURL != nil else { return }
        guard toggleToolWindow(.agent) else { return }
        activateAgentConversation()
    }

    func activateAgentConversation() {
        guard isAgentConversationEnabled, agentConversationFeatureIfActive == nil else {
            connectAgentConversation()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await awaitModuleRuntimeShutdown()
                _ = try await services.moduleRuntime.activateCapability(.agentConversation)
                objectWillChange.send()
                connectAgentConversation()
            } catch {
                showNotification(error.localizedDescription)
            }
        }
    }

    /// Why a message cannot be sent right now, before any Agent is involved.
    var agentConversationSetupError: AgentConversationError? {
        if !isAgentConversationEnabled { return .featureDisabled }
        if configuredAgentOptions.isEmpty { return .noAgentConfigured }
        if agentConversationFeatureIfActive == nil { return .moduleStarting }
        return nil
    }

    /// Which local CLI configuration an agent follows, if any.
    static func localConfigurationSource(for agentID: String) -> AIConfigurationSourceKind? {
        switch agentID {
        case "codex-acp": .codex
        case "claude-acp": .claude
        default: nil
        }
    }

    /// Read the user's own CLI configuration (endpoint, model, API key) and
    /// bind it to `agentID`. Lithe keeps following that file; nothing is
    /// copied into Lithe settings except the provider profile. The commit
    /// message provider is left untouched.
    @discardableResult
    func importLocalConfiguration(for agentID: String, source: AIConfigurationSourceKind, name: String) -> Bool {
        guard let configuration = loadAIConfigurations().first(where: { $0.source == source }) else {
            detectedAIConfigurations.removeAll { $0.source == source }
            showNotification(String(format: String(localized: "No %@ configuration was found on this Mac."), source.title))
            return false
        }
        let commitProviderID = settings.commitMessageAI.activeProviderID
        let provider = settings.importAIConfiguration(configuration)
        settings.commitMessageAI.activeProviderID = commitProviderID
        try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        detectedAIConfigurations.removeAll { $0.source == source }
        detectedAIConfigurations.append(configuration)
        settings.setAgentProvider(provider.id, for: agentID, name: name)
        showNotification(String(format: String(localized: "%@ now follows your local %@ configuration."), name, source.title))
        return true
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
            .map { id, configuration -> AgentOption in
                let provider = settings.agentProvider(for: id)
                let model = provider?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return AgentOption(id: id, name: configuration.name, modelName: model.isEmpty ? provider?.name : model)
            }
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
            // Refresh the displayed fallback even when credential validation fails.
            defer { feature.setAgents(configuredAgentOptions) }
            let configuration = try agentLaunchConfiguration(agentID: agentID)
            try connection.connect(configuration: configuration)
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
        // A saved import is not the current CLI default. Read through the same
        // configuration ports used for credentials, once at connection startup.
        settings.refreshAgentModels(from: services.aiConfigurationSources.compactMap { $0.loadModel() })
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
