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

/// What the native adapter must do to reverse one file's Agent edits.
enum AgentEditReversePlan: Equatable, Sendable {
    /// Guarded write of the restored text in the disk's encoding.
    case write(String)
    /// The file did not exist before the edits; move it to Trash.
    case trash
    /// The disk already matches the state before the edits.
    case none
}

/// Plans a rollback from evidence and the current disk text. Conflicts throw
/// ``AgentEditRestoreError`` so nothing is written.
protocol AgentEditReversePlanning: Sendable {
    func reversePlan(for change: AgentFileChange, disk: String?) throws -> AgentEditReversePlan
}

struct UnavailableAgentEditRestorer: AgentEditRestoring {
    func restore(_ change: AgentFileChange, in workspace: URL) async throws { throw AgentEditRestoreError.unavailable }
}
