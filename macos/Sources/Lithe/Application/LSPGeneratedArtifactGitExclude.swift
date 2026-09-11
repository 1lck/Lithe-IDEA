import Foundation

/// Outcome of the one-shot Git local-exclude half of the recommended-rules action.
/// Hidden paths are persisted first; this value only describes the Git write.
enum LSPGeneratedArtifactGitExcludeResult: Equatable, Sendable {
    case updated
    case noRepository
    case failed
}

enum LSPGeneratedArtifactGitExcludeOutcome {
    /// Maps a GitService write onto the Settings notification cases.
    ///
    /// Core reports a missing repository as `invalid_request` / "Not a Git
    /// repository". Hosts may append details after a colon.
    static func classify(
        succeeded: Bool,
        output: String,
        operationErrorMessage: String?
    ) -> LSPGeneratedArtifactGitExcludeResult {
        if succeeded {
            return .updated
        }
        let message = operationErrorMessage ?? output
        if message.hasPrefix("Not a Git repository") {
            return .noRepository
        }
        return .failed
    }
}
