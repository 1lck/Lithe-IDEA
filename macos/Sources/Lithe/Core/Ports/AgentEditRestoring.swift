import Foundation
import LitheModuleAPI
import LitheAgentConversationModule

/// Native adapters own workspace path checks, encoding, guarded writes and Trash.
protocol AgentEditRestoring: Sendable {
    func restore(_ change: AgentFileChange, in workspace: URL) async throws
}

enum AgentEditRestoreError: LocalizedError {
    case unavailable, outsideWorkspace, changed, dirtyBuffer, incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.string("Agent change rollback is unavailable.")
        case .outsideWorkspace: L10n.string("This file is outside the current project.")
        case .changed: L10n.string("The file has changed since the Agent edit. Open the diff and review it manually.")
        case .dirtyBuffer: L10n.string("This file has unsaved editor changes. Save or discard them before rolling back the Agent edit.")
        case .incomplete: L10n.string("The Agent did not provide enough original content to safely roll back this file.")
        }
    }
}

struct UnavailableAgentEditRestorer: AgentEditRestoring {
    func restore(_ change: AgentFileChange, in workspace: URL) async throws { throw AgentEditRestoreError.unavailable }
}
