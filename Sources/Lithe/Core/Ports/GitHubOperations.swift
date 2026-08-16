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

struct GitHubPullRequestBranchDefaults: Equatable, Sendable {
    let head: String?
    let base: String?
    let requiresPublish: Bool
    let isDetached: Bool
    let suggestedPublishBranch: String?
    let hasUncommittedChanges: Bool

    init(
        head: String?,
        base: String?,
        requiresPublish: Bool = false,
        isDetached: Bool = false,
        suggestedPublishBranch: String? = nil,
        hasUncommittedChanges: Bool = false
    ) {
        self.head = head
        self.base = base
        self.requiresPublish = requiresPublish
        self.isDetached = isDetached
        self.suggestedPublishBranch = suggestedPublishBranch
        self.hasUncommittedChanges = hasUncommittedChanges
    }
}

protocol GitHubGitOperations: Sendable {
    func originRemote(at workspaceURL: URL) throws -> String
    func pullRequestBranchDefaults(at workspaceURL: URL) throws -> GitHubPullRequestBranchDefaults
    func publishPullRequestBranch(named name: String, at workspaceURL: URL) throws
    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, at workspaceURL: URL) throws
}
