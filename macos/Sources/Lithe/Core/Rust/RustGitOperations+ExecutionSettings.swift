import Foundation
import LitheGitModule

extension RustGitOperations {
    func executionSettings(_ request: GitConfigurationEdit, save: Bool) -> Result<GitExecutionSettingsSnapshot, GitFetchFailure> {
        core.executeResult(command: save ? "git.executionConfigure" : "git.executionInspect", payload: request)
            .mapError { GitFetchFailure($0.userMessage) }
    }
    func remoteURL(at rootURL: URL, remote: String) -> String? {
        switch core.gitRemoteURL(at: rootURL, remote: remote) {
        case .success(let url): return url
        case .failure: return nil
        }
    }
    func answerAuthentication(requestID: String, answer: String?) -> Bool {
        struct Reply: Encodable { let requestId: String; let answer: String? }
        struct Response: Decodable { let accepted: Bool }
        let result: Result<Response, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "git.authRespond", payload: Reply(requestId: requestID, answer: answer))
        return (try? result.get().accepted) ?? false
    }
}
