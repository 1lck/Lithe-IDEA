import SwiftUI
import LitheAgentConversationModule
import LitheCoreContracts

/// Both file entry points resolve live destinations when their context menu opens.
enum AgentFileAttachmentMenu {
    @MainActor
    static func items(model: AppModel, urls: [URL]) -> [LitheContextMenuItem] {
        guard let workspace = model.currentWorkspaceIdentity else { return [] }
        let files = urls.filter { model.services.fileStorage.metadata(for: $0)?.isRegularFile == true }
        guard !files.isEmpty else { return [] }
        let agents = model.configuredAgentOptions
        guard model.isAgentConversationEnabled, !agents.isEmpty else {
            return [.action("Set Up Agent File Attachments…") { model.showAgentSettings() }]
        }
        let feature = model.agentConversationFeatureIfActive
        let currentID = feature?.selectedAgentID ?? model.selectedAgentConversationID
        let currentSession = feature?.selectedConnection?.selectedSessionID
        return items(agents: agents, currentAgentID: currentID, currentSessionID: currentSession,
                     sessions: { feature?.fileAttachmentSessions(for: $0) ?? [] }) { agentID, destination in
            Task { @MainActor in
                await model.attachFilesToAgent(files, agentID: agentID, destination: destination, workspace: workspace)
            }
        }
    }

    static func items(agents: [AgentOption], currentAgentID: String?, currentSessionID: String?,
                      sessions: (String) -> [AgentSessionSummary],
                      attach: @escaping (String, AgentFileAttachmentDestination) -> Void) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        if let current = agents.first(where: { $0.id == currentAgentID }) {
            let destination = currentSessionID.map(AgentFileAttachmentDestination.session) ?? .current
            items.append(.action(String(format: String(localized: "Add to Current Conversation · %@"), current.name),
                                 localizesTitle: false) { attach(current.id, destination) })
        }
        var choices: [LitheContextMenuItem] = []
        for agent in agents {
            let history = sessions(agent.id)
            if !choices.isEmpty { choices.append(.separator) }
            var heading = LitheContextMenuItem.action(agent.name, localizesTitle: false, isEnabled: false, action: {})
            heading.isCenteredHeading = true
            choices.append(heading)
            choices.append(.action("New Conversation") { attach(agent.id, .newConversation) })
            if !history.isEmpty {
                choices += history.map { session in
                    .action(session.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                            ?? String(localized: "Untitled conversation"), localizesTitle: false,
                            description: String(session.id.prefix(8)),
                            checked: currentAgentID == agent.id && currentSessionID == session.id) {
                        attach(agent.id, .session(session.id))
                    }
                }
            }
        }
        items.append(.submenu("Add to Another Conversation", items: choices))
        return items
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
