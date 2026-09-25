import Foundation
import LitheAgentConversationModule
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
            } catch {
                workbenchFeature.setVisibility(.agent, isVisible: false)
                showNotification(error.localizedDescription)
            }
        }
    }
}
