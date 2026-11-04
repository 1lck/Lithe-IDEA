import Foundation
import LitheCoreContracts

protocol GitHubCorePlanning: Sendable {
    func parseRemote(_ remoteURL: String) throws -> GitHubRepository
    func requestPlan(_ request: GitHubRequest) throws -> GitHubRequestPlan
    func normalizeResponse(operation: String, status: Int, body: String) throws -> GitHubNormalizedResponse
    func deviceAuthorizationTransition(_ request: GitHubDeviceTransitionRequest) throws -> GitHubDeviceTransition
}

struct GitHubDeviceTransitionRequest: Codable, Sendable {
    let event: String
    let expiresIn: UInt64
    let interval: UInt64
    let elapsedMilliseconds: UInt64
    let suggestedInterval: UInt64?
}

struct GitHubDeviceTransition: Decodable, Equatable, Sendable {
    let action: String
    let intervalSeconds: UInt64
    let waitMilliseconds: UInt64
}

struct GitHubCheckoutPreview: Decodable, Sendable {
    struct Plan: Decodable, Equatable, Sendable {
        let allowed: Bool
        let branch: String
        let conflict: String?
        let actions: [String]
    }
    let plan: Plan
    let head: String
    let currentBranch: String?
    let originFingerprint: String
}

struct GitHubCheckoutIntent: Sendable {
    let workspaceURL: URL
    let request: GitHubPullRequest
    let repository: GitHubRepository
    let preview: GitHubCheckoutPreview
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
    func previewCheckout(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL) throws -> GitHubCheckoutPreview
    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL, preview: GitHubCheckoutPreview) throws
}
