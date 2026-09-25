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

    /// Start this project's Agent when the panel is shown; errors stay in the panel.
    func connectAgentConversation() {
        guard let feature = agentConversationFeatureIfActive, !feature.hasActiveConnection else { return }
        feature.onAttentionChanged = { [weak self] needsAttention in
            self?.agentConversationNeedsAttention = needsAttention
        }
        do {
            try feature.connect(configuration: agentLaunchConfiguration())
        } catch {
            // The panel shows the reason and offers a retry.
            feature.reportConnectionFailure(error.localizedDescription)
        }
    }

    func agentLaunchConfiguration() throws -> AgentLaunchConfiguration {
        guard let workspaceURL else { throw AgentConversationError.notConnected }
        let command = settings.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw AgentConversationError.missingCommand }
        guard let provider = settings.agentProvider else { throw AgentConversationError.missingProvider }
        let apiKey = services.credentialResolver.readAPIKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw AgentConversationError.missingAPIKey }
        // One argument per line, passed to the process without shell parsing.
        let arguments = settings.agentArguments
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return AgentLaunchConfiguration(
            command: command,
            arguments: arguments,
            workspaceURL: workspaceURL,
            gatewayBaseURL: provider.endpoint,
            apiKey: apiKey,
            providerName: provider.name,
            allowsInsecureHTTP: provider.allowsInsecureHTTP
        )
    }
}
