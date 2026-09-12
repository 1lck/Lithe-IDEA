import Foundation
import LitheGitModule

extension RustCoreBridge {
    private struct FetchPlanRequest: Encodable { let options: GitFetchOptions }
    private struct FetchRequest: Encodable {
        let root: String
        let operation = "fetch"
        let fetchOptions: GitFetchOptions
    }

    func gitFetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, CoreCallError> {
        executeResult(command: "git.fetchPlan", payload: FetchPlanRequest(options: options))
    }

    func gitFetch(at root: URL, options: GitFetchOptions, operationID: String) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(command: "git.write", payload: FetchRequest(
            root: root.standardizedFileURL.path, fetchOptions: options
        ), operationID: operationID)
    }
}

extension RustGitOperations {
    func fetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, GitFetchFailure> {
        core.gitFetchPlan(options: options).mapError { GitFetchFailure($0.userMessage) }
    }

    func fetch(at rootURL: URL, options: GitFetchOptions, operationID: String) -> GitProcessResult? {
        switch core.gitFetch(at: rootURL, options: options, operationID: operationID) {
        case .success(let response): return makeProcessResult(response)
        case .failure(let error): return GitProcessResult(output: error.userMessage, exitCode: 1)
        }
    }
}
