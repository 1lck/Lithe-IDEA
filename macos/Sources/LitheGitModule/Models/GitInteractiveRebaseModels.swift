import Foundation

package enum GitRebaseAction: String, Codable, CaseIterable, Sendable {
    case pick, reword, edit, squash, fixup, drop
}

package struct GitRebaseStep: Codable, Equatable, Sendable, Identifiable {
    package let hash: String
    package var action: GitRebaseAction
    package var message: String?
    package var id: String { hash }

    package init(hash: String, action: GitRebaseAction, message: String? = nil) {
        self.hash = hash
        self.action = action
        self.message = message
    }
}

/// Kept separate from the four history shortcuts; Core owns the operation and state token.
package struct GitRebaseExpectedState: Codable, Equatable, Sendable {
    package let branch: String
    package let head: String
    package let stateToken: String
    package let operation: String
    package let revisions: [String]
}

package struct GitRebasePreview: Decodable, Equatable, Sendable {
    package let allowed: Bool
    package let blockers: [GitHistoryRewriteBlocker]
    package let branch: String?
    package let head: String?
    package let base: String?
    package let commits: [GitHistoryRewriteCommit]
    package let expectedState: GitRebaseExpectedState?
}

package enum GitRebaseSessionStatus: String, Decodable, Sendable {
    case starting, conflict, edit, paused, completed, aborted, failed, interrupted
}

package struct GitRebaseSession: Decodable, Equatable, Sendable {
    package let sessionId: String
    package let status: GitRebaseSessionStatus
    package let branch: String
    package let originalHead: String
    package let head: String?
    package let recoveryReference: String
    package let steps: [GitRebaseStep]
    package let completedSteps: Int
    package let currentCommit: String?
    package let currentMessage: String?
    package let conflictedPaths: [String]
    package let canContinue: Bool
    package let canSkip: Bool
    package let canAbort: Bool

    package var isActive: Bool { canContinue || canSkip || canAbort || status == .starting }
}

package enum GitRebaseControlAction: String, Encodable, Sendable {
    case `continue`, skip, abort
}

package struct GitRebaseFailure: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

package struct GitRebaseProcessResult: Sendable {
    package let command: GitProcessResult
    package let session: GitRebaseSession?

    package init(command: GitProcessResult, session: GitRebaseSession?) {
        self.command = command
        self.session = session
    }
}

package struct GitRebaseMutationResult: Sendable {
    package let command: GitService.CommandResult
    package let session: GitRebaseSession?
}
