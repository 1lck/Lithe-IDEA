import Foundation
import LitheCoreContracts

/// A user-selected draft destination within one configured Agent and workspace.
public enum AgentFileAttachmentDestination: Equatable, Sendable {
    case current
    case newConversation
    case session(String)
}

public enum AgentFileAttachmentError: LocalizedError {
    case sessionUnavailable
    case agentUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionUnavailable: "This conversation is no longer available. Choose another conversation."
        case .agentUnavailable: "This Agent is no longer configured. Open Agent settings to configure it."
        }
    }
}

extension AgentConversationFeatureModel {
    /// Cached history only: building a context menu must not start another Agent.
    public func fileAttachmentSessions(for agentID: String) -> [AgentSessionSummary] {
        guard let connection = existingConnection(for: agentID) else { return [] }
        let metadata = existingHistoryMetadata(for: agentID)
        return connection.sessions.compactMap { session in
            guard metadata[session.id]?.isHidden != true else { return nil }
            var session = session
            session.title = metadata[session.id]?.title ?? session.title
            return session
        }
    }

    public func attachFiles(_ urls: [URL], agentID: String, to destination: AgentFileAttachmentDestination) throws {
        guard agents.contains(where: { $0.id == agentID }) else { throw AgentFileAttachmentError.agentUnavailable }
        if case .session(let id) = destination {
            guard fileAttachmentSessions(for: agentID).contains(where: { $0.id == id }) else {
                throw AgentFileAttachmentError.sessionUnavailable
            }
        }
        let connection = connection(for: agentID)
        try connection.attachFiles(urls, to: destination)
        selectAgent(agentID)
    }
}
