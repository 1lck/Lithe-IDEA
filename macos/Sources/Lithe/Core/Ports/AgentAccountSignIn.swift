import Foundation
import LitheModuleAPI

/// Runs the official CLI login for one subscription account without a terminal.
/// The CLI opens its own browser flow and keeps every credential; Lithe only
/// learns whether the command finished.
protocol AgentAccountSigningIn: Sendable {
    /// Returns after the login command succeeds. Cancelling the task stops it.
    func signIn(agentID: String, directory: URL) async throws
}

enum AgentAccountSignInError: LocalizedError, Equatable {
    case unsupported, failed, timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.string("This Agent has no account sign-in.")
        case .failed: L10n.string("Sign-in did not finish. Check that the Agent's CLI is installed, then try again.")
        case .timedOut: L10n.string("Sign-in timed out. Try again.")
        }
    }
}

struct UnavailableAgentAccountSignIn: AgentAccountSigningIn {
    func signIn(agentID: String, directory: URL) async throws { throw AgentAccountSignInError.unsupported }
}
