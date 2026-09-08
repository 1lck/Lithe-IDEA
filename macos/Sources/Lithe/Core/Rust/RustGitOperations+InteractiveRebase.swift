import Foundation
import LitheGitModule

extension RustGitOperations {
    func interactiveRebasePreview(at rootURL: URL, revision: String) -> Result<GitRebasePreview, GitRebaseFailure> {
        core.gitRebasePreview(at: rootURL, revision: revision).mapError { GitRebaseFailure($0.userMessage) }
    }

    func interactiveRebaseSession(at rootURL: URL) -> Result<GitRebaseSession?, GitRebaseFailure> {
        core.gitRebaseSession(at: rootURL).mapError { GitRebaseFailure($0.userMessage) }
    }

    func startInteractiveRebase(at rootURL: URL, expectedState: GitRebaseExpectedState, steps: [GitRebaseStep]) -> GitRebaseProcessResult {
        rebaseResult(core.gitRebaseStart(at: rootURL, expectedState: expectedState, steps: steps))
    }

    func controlInteractiveRebase(at rootURL: URL, sessionId: String, action: GitRebaseControlAction, amendMessage: String?) -> GitRebaseProcessResult {
        rebaseResult(core.gitRebaseControl(at: rootURL, sessionId: sessionId, action: action, amendMessage: amendMessage))
    }

    private func rebaseResult(_ response: Result<RustCoreBridge.GitRebaseMutationPayload, RustCoreBridge.CoreCallError>) -> GitRebaseProcessResult {
        switch response {
        case .success(let payload):
            GitRebaseProcessResult(command: makeProcessResult(payload.command), session: payload.session)
        case .failure(let error):
            GitRebaseProcessResult(command: GitProcessResult(output: error.userMessage, standardError: error.userMessage, exitCode: 1), session: nil)
        }
    }
}
