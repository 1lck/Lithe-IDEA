import Foundation
import LitheAgentConversationModule

/// Native adapters own workspace path checks, encoding, guarded writes and Trash.
protocol AgentEditRestoring: Sendable {
    func restore(_ change: AgentFileChange, in workspace: URL) async throws
}

enum AgentEditRestoreError: LocalizedError {
    case unavailable, outsideWorkspace, changed, dirtyBuffer, incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Agent change rollback is unavailable.")
        case .outsideWorkspace: String(localized: "This file is outside the current project.")
        case .changed: String(localized: "The file has changed since the Agent edit. Open the diff and review it manually.")
        case .dirtyBuffer: String(localized: "This file has unsaved editor changes. Save or discard them before rolling back the Agent edit.")
        case .incomplete: String(localized: "The Agent did not provide enough original content to safely roll back this file.")
        }
    }
}

struct UnavailableAgentEditRestorer: AgentEditRestoring {
    func restore(_ change: AgentFileChange, in workspace: URL) async throws { throw AgentEditRestoreError.unavailable }
}
