import Foundation
import LitheCoreContracts

actor GitHubService {
    enum ServiceError: LocalizedError {
        case oauthClientNotConfigured
        case authorizationExpired
        case authorizationDenied
        case authorizationFailed(String)
        case invalidResponse
        case noWorkspace
        case missingToken
        case mergeRejected(String)

        var errorDescription: String? {
            switch self {
            case .oauthClientNotConfigured:
                "GitHub Device Flow is not configured. Add a fine-grained token or configure LitheGitHubOAuthClientID."
            case .authorizationExpired: "The GitHub authorization code expired. Start again."
            case .authorizationDenied: "GitHub authorization was cancelled."
            case .authorizationFailed(let message): "GitHub authorization failed: \(message)"
            case .invalidResponse: "GitHub returned an unexpected response"
            case .noWorkspace: "Open a Git project before using pull requests"
            case .missingToken: "Connect a GitHub account before continuing"
            case .mergeRejected(let message): message
            }
        }
    }

    private enum Constants {
        static let tokenKey = "oauth-token"
        static let slowDownSeconds: UInt64 = 5
    }

    private let core: any GitHubCorePlanning
    private let transport: any GitHubHTTPTransport
    private let configuration: any GitHubConfiguration
    private let secureStore: any SecureStore
    private let git: any GitHubGitOperations
    private var token: String?

    init(
        core: any GitHubCorePlanning,
        transport: any GitHubHTTPTransport,
        configuration: any GitHubConfiguration,
        secureStore: any SecureStore,
        git: any GitHubGitOperations
    ) {
        self.core = core
        self.transport = transport
        self.configuration = configuration
        self.secureStore = secureStore
        self.git = git
    }

    var canUseDeviceFlow: Bool { configuration.oauthClientID != nil }

    func restoreConnection() async throws -> GitHubUser? {
        guard let storedToken = secureStore.read(key: Constants.tokenKey), !storedToken.isEmpty else {
            return nil
        }
        do {
            let user = try await currentUser(using: storedToken)
            token = storedToken
            return user
        } catch {
            // A network or GitHub outage must not destroy a valid credential.
            // The user can explicitly disconnect or replace an invalid token.
            throw error
        }
    }

    func startDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        guard let clientID = configuration.oauthClientID else {
            throw ServiceError.oauthClientNotConfigured
        }
        let response = try await perform(
            GitHubRequest(operation: "deviceCode", clientID: clientID),
            token: nil
        )
        guard case .deviceAuthorization(let authorization) = response else {
            throw ServiceError.invalidResponse
        }
        return authorization
    }

    func finishDeviceAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubUser {
        guard let clientID = configuration.oauthClientID else {
            throw ServiceError.oauthClientNotConfigured
        }
        let expirationSeconds = min(max(authorization.expiresIn, 1), 86_400)
        let deadline = ContinuousClock.now + .seconds(Int64(expirationSeconds))
        var interval = min(max(authorization.interval, 1), 60)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(Int64(interval)))
            let response = try await perform(
                GitHubRequest(
                    operation: "deviceToken",
                    clientID: clientID,
                    deviceCode: authorization.deviceCode
                ),
                token: nil
            )
            guard case .deviceToken(let result) = response else {
                throw ServiceError.invalidResponse
            }
            switch result.status {
            case "authorized":
                guard let accessToken = result.accessToken, !accessToken.isEmpty else {
                    throw ServiceError.invalidResponse
                }
                return try await saveAndValidate(accessToken)
            case "pending":
                continue
            case "slowDown":
                interval = min(
                    max(result.interval ?? interval, interval) + Constants.slowDownSeconds,
                    60
                )
            case "expired":
                throw ServiceError.authorizationExpired
            case "denied":
                throw ServiceError.authorizationDenied
            default:
                throw ServiceError.authorizationFailed(result.message ?? result.error ?? "Unknown error")
            }
        }
        throw ServiceError.authorizationExpired
    }

    func connect(personalAccessToken: String) async throws -> GitHubUser {
        let value = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ServiceError.missingToken }
        return try await saveAndValidate(value)
    }

    func disconnect() throws {
        token = nil
        try secureStore.delete(key: Constants.tokenKey)
    }

    func resolveRepository(at workspaceURL: URL?) throws -> GitHubRepository {
        guard let workspaceURL else { throw ServiceError.noWorkspace }
        return try core.parseRemote(git.originRemote(at: workspaceURL))
    }

    func listPullRequests(repository: GitHubRepository, state: String = "open") async throws -> [GitHubPullRequest] {
        let response = try await perform(
            GitHubRequest(operation: "listPullRequests", repository: repository, state: state)
        )
        guard case .pullRequests(let requests) = response else { throw ServiceError.invalidResponse }
        return requests
    }

    func pullRequest(repository: GitHubRepository, number: UInt64) async throws -> GitHubPullRequest {
        let response = try await perform(
            GitHubRequest(operation: "getPullRequest", repository: repository, pullNumber: number)
        )
        guard case .pullRequest(let request) = response else { throw ServiceError.invalidResponse }
        return request
    }

    func createPullRequest(
        repository: GitHubRepository,
        title: String,
        body: String,
        head: String,
        base: String,
        draft: Bool
    ) async throws -> GitHubPullRequest {
        let response = try await perform(GitHubRequest(
            operation: "createPullRequest",
            repository: repository,
            title: title,
            body: body,
            head: head,
            base: base,
            draft: draft
        ))
        guard case .pullRequest(let request) = response else { throw ServiceError.invalidResponse }
        return request
    }

    func updatePullRequest(
        repository: GitHubRepository,
        number: UInt64,
        title: String? = nil,
        body: String? = nil,
        base: String? = nil,
        state: String? = nil
    ) async throws -> GitHubPullRequest {
        let response = try await perform(GitHubRequest(
            operation: "updatePullRequest",
            repository: repository,
            pullNumber: number,
            title: title,
            body: body,
            base: base,
            state: state
        ))
        guard case .pullRequest(let request) = response else { throw ServiceError.invalidResponse }
        return request
    }

    func files(repository: GitHubRepository, number: UInt64) async throws -> [GitHubPullRequestFile] {
        let response = try await perform(GitHubRequest(
            operation: "listPullRequestFiles",
            repository: repository,
            pullNumber: number
        ))
        guard case .files(let files) = response else { throw ServiceError.invalidResponse }
        return files
    }

    func comments(repository: GitHubRepository, number: UInt64) async throws -> [GitHubComment] {
        let response = try await perform(GitHubRequest(
            operation: "listPullRequestComments",
            repository: repository,
            pullNumber: number
        ))
        guard case .comments(let comments) = response else { throw ServiceError.invalidResponse }
        return comments
    }

    func addComment(repository: GitHubRepository, number: UInt64, body: String) async throws -> GitHubComment {
        let response = try await perform(GitHubRequest(
            operation: "createPullRequestComment",
            repository: repository,
            pullNumber: number,
            body: body
        ))
        guard case .comment(let comment) = response else { throw ServiceError.invalidResponse }
        return comment
    }

    func submitReview(
        repository: GitHubRepository,
        number: UInt64,
        event: String,
        body: String
    ) async throws {
        let response = try await perform(GitHubRequest(
            operation: "createPullRequestReview",
            repository: repository,
            pullNumber: number,
            body: body,
            event: event
        ))
        guard case .review = response else { throw ServiceError.invalidResponse }
    }

    func merge(
        repository: GitHubRepository,
        number: UInt64,
        method: String
    ) async throws -> GitHubMergeResult {
        let response = try await perform(GitHubRequest(
            operation: "mergePullRequest",
            repository: repository,
            pullNumber: number,
            mergeMethod: method
        ))
        guard case .merge(let result) = response else { throw ServiceError.invalidResponse }
        guard result.merged else { throw ServiceError.mergeRejected(result.message) }
        return result
    }

    func updateMetadata(
        repository: GitHubRepository,
        number: UInt64,
        labels: [String],
        assignees: [String]
    ) async throws {
        let response = try await perform(GitHubRequest(
            operation: "updatePullRequestMetadata",
            repository: repository,
            pullNumber: number,
            labels: labels,
            assignees: assignees
        ))
        guard case .metadata = response else { throw ServiceError.invalidResponse }
    }

    func checkout(_ pullRequest: GitHubPullRequest, at workspaceURL: URL?) throws {
        guard let workspaceURL else { throw ServiceError.noWorkspace }
        try git.checkoutPullRequest(pullRequest, at: workspaceURL)
    }

    private func saveAndValidate(_ accessToken: String) async throws -> GitHubUser {
        let user = try await currentUser(using: accessToken)
        try secureStore.write(accessToken, key: Constants.tokenKey)
        token = accessToken
        return user
    }

    private func currentUser(using accessToken: String) async throws -> GitHubUser {
        let response = try await perform(
            GitHubRequest(operation: "currentUser"),
            token: accessToken
        )
        guard case .user(let user) = response else { throw ServiceError.invalidResponse }
        return user
    }

    private func perform(
        _ request: GitHubRequest,
        token tokenOverride: String? = nil
    ) async throws -> GitHubNormalizedResponse {
        let plan = try core.requestPlan(request)
        let credential = tokenOverride ?? token
        if plan.requiresAuthentication, credential == nil {
            throw ServiceError.missingToken
        }
        let raw = try await transport.execute(plan: plan, token: credential)
        return try core.normalizeResponse(
            operation: request.operation,
            status: raw.status,
            body: raw.body
        )
    }
}
