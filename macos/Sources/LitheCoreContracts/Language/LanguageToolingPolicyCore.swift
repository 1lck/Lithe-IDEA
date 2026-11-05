import Foundation

/// Startup failure history returned by Rust Core (`lsp.activationPolicy`).
/// The session manager stores it per provider and workspace root verbatim.
package struct LanguageServerActivationState: Codable, Equatable, Sendable {
    package let consecutiveFailures: Int
    /// Monotonic milliseconds of the latest failure.
    package let lastFailureAtMs: UInt64

    package init(consecutiveFailures: Int, lastFailureAtMs: UInt64) {
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureAtMs = lastFailureAtMs
    }
}

package enum LanguageServerActivationEvent: String, Codable, Sendable {
    /// A start triggered by opening or synchronizing a document.
    case automaticStart
    /// A start the user requested.
    case explicitStart
    /// A start or a running session failed.
    case startFailed
    /// The session reached its ready state.
    case ready
}

package enum LanguageServerActivationDecision: String, Codable, Sendable {
    case allow
    case wait
    case explicitRetryRequired
}

package struct LanguageServerActivationOutcome: Codable, Equatable, Sendable {
    package let state: LanguageServerActivationState?
    package let decision: LanguageServerActivationDecision
    package let retryAfterMs: UInt64?

    package init(state: LanguageServerActivationState?, decision: LanguageServerActivationDecision,
                 retryAfterMs: UInt64?) {
        self.state = state
        self.decision = decision
        self.retryAfterMs = retryAfterMs
    }
}

/// Candidates to keep after merging prioritized completion providers.
package struct CompletionMergeSelection: Equatable, Sendable {
    /// For each submitted list, the indices to keep in order.
    package let keep: [[Int]]
    package let isIncomplete: Bool

    package init(keep: [[Int]], isIncomplete: Bool) {
        self.keep = keep
        self.isIncomplete = isIncomplete
    }
}

/// A Core call that could not be answered, identified by its stable error code.
package struct LanguageToolingPolicyFailure: Error, Equatable, Sendable {
    package let code: String

    package init(code: String) {
        self.code = code
    }
}

/// Shared language-tooling rules evaluated by Rust Core. A failure means Core
/// could not answer; the caller logs it and keeps the session usable.
package protocol LanguageToolingPolicyCore: Sendable {
    func languageServerActivation(
        state: LanguageServerActivationState?,
        event: LanguageServerActivationEvent,
        nowMs: UInt64
    ) -> Result<LanguageServerActivationOutcome, LanguageToolingPolicyFailure>

    /// `lists` are completion labels ordered from the highest-priority provider.
    func mergeCompletions(
        labels lists: [[String]], incomplete: [Bool]
    ) -> Result<CompletionMergeSelection, LanguageToolingPolicyFailure>
}
