import Foundation
import LitheCoreContracts

protocol GitHubCorePlanning: Sendable {
    func parseRemote(_ remoteURL: String) throws -> GitHubRepository
    func requestPlan(_ request: GitHubRequest) throws -> GitHubRequestPlan
    func normalizeResponse(operation: String, status: Int, body: String) throws -> GitHubNormalizedResponse
}

struct GitHubHTTPResponse: Sendable {
    let status: Int
    let body: String
}

protocol GitHubHTTPTransport: Sendable {
    func execute(plan: GitHubRequestPlan, token: String?) async throws -> GitHubHTTPResponse
}

protocol GitHubConfiguration: Sendable {
    var oauthClientID: String? { get }
}

protocol GitHubGitOperations: Sendable {
    func originRemote(at workspaceURL: URL) throws -> String
    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, at workspaceURL: URL) throws
}
