import Foundation
import LitheGitModule

extension RustCoreBridge {
    struct GitRebaseMutationPayload: Decodable {
        let command: GitCommandPayload
        let session: GitRebaseSession?
    }

    private struct RebasePreviewRequest: Encodable {
        let root: String
        let revision: String
    }

    private struct RebaseStartRequest: Encodable {
        let root: String
        let expectedState: GitRebaseExpectedState
        let steps: [GitRebaseStep]
    }

    private struct RebaseSessionRequest: Encodable {
        let root: String
    }

    private struct RebaseControlRequest: Encodable {
        let root: String
        let sessionId: String
        let action: GitRebaseControlAction
        let amendMessage: String?
        let expectedHead: String?
    }

    func gitRebasePreview(at root: URL, revision: String) -> Result<GitRebasePreview, CoreCallError> {
        executeResult(command: "git.rebasePreview", payload: RebasePreviewRequest(root: root.standardizedFileURL.path, revision: revision))
    }

    func gitRebaseStart(at root: URL, expectedState: GitRebaseExpectedState, steps: [GitRebaseStep]) -> Result<GitRebaseMutationPayload, CoreCallError> {
        executeResult(command: "git.rebaseStart", payload: RebaseStartRequest(root: root.standardizedFileURL.path, expectedState: expectedState, steps: steps))
    }

    func gitRebaseSession(at root: URL) -> Result<GitRebaseSession?, CoreCallError> {
        executeNullableResult(command: "git.rebaseSession", payload: RebaseSessionRequest(root: root.standardizedFileURL.path))
    }

    func gitRebaseControl(at root: URL, sessionId: String, action: GitRebaseControlAction, amendMessage: String?, expectedHead: String?) -> Result<GitRebaseMutationPayload, CoreCallError> {
        executeResult(command: "git.rebaseControl", payload: RebaseControlRequest(root: root.standardizedFileURL.path, sessionId: sessionId, action: action, amendMessage: amendMessage, expectedHead: expectedHead))
    }
}
