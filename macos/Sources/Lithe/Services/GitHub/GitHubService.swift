import LitheModuleAPI
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
                L10n.string("GitHub sign-in is unavailable in this build.")
            case .authorizationExpired: L10n.string("The GitHub authorization code expired. Start again.")
            case .authorizationDenied: L10n.string("GitHub authorization was cancelled.")
            case .authorizationFailed(let message): L10n.string("GitHub authorization failed: \(message)")
            case .invalidResponse: L10n.string("GitHub returned an unexpected response")
            case .noWorkspace: L10n.string("Open a Git project before using pull requests")
            case .missingToken: L10n.string("Connect a GitHub account before continuing")
            case .mergeRejected(let message): message
            }
        }
    }

    private enum Constants {
        static let tokenKey = "oauth-token"
        private static let deviceClockEpoch = ContinuousClock.now

        static func deviceNowMilliseconds() -> UInt64 {
            let elapsed = deviceClockEpoch.duration(to: .now).components
            return UInt64(max(elapsed.seconds, 0)) * 1_000
                + UInt64(max(elapsed.attoseconds, 0) / 1_000_000_000_000_000)
        }
    }

    private let core: any GitHubCorePlanning
    private let transport: any GitHubHTTPTransport
    private let configuration: any GitHubConfiguration
    private let secureStore: any SecureStore
    private let git: any GitHubGitOperations
    private let deviceNowMilliseconds: @Sendable () -> UInt64
    private let deviceSleep: @Sendable (UInt64) async throws -> Void
    private var token: String?
    private var deviceAuthorizationStarted: (code: String, milliseconds: UInt64)?

    init(
        core: any GitHubCorePlanning,
        transport: any GitHubHTTPTransport,
        configuration: any GitHubConfiguration,
        secureStore: any SecureStore,
        git: any GitHubGitOperations,
        deviceNowMilliseconds: @escaping @Sendable () -> UInt64 = { Constants.deviceNowMilliseconds() },
        deviceSleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int64($0))) }
    ) {
        self.core = core
        self.transport = transport
        self.configuration = configuration
        self.secureStore = secureStore
        self.git = git
        self.deviceNowMilliseconds = deviceNowMilliseconds
        self.deviceSleep = deviceSleep
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
        // Count request latency too: the server may issue the code before its response arrives.
        let started = deviceNowMilliseconds()
        let response = try await perform(
            GitHubRequest(operation: "deviceCode", clientID: clientID),
            token: nil
        )
        guard case .deviceAuthorization(let authorization) = response else {
            throw ServiceError.invalidResponse
        }
        deviceAuthorizationStarted = (authorization.deviceCode, started)
        return authorization
    }

    func finishDeviceAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubUser {
        guard let clientID = configuration.oauthClientID else {
            throw ServiceError.oauthClientNotConfigured
        }
        guard let saved = deviceAuthorizationStarted, saved.code == authorization.deviceCode else {
            throw ServiceError.authorizationExpired
        }
        let started = saved.milliseconds
        defer {
            if deviceAuthorizationStarted?.code == authorization.deviceCode { deviceAuthorizationStarted = nil }
        }
        var interval = authorization.interval
        var event = "start"
        var result: GitHubDeviceTokenResponse?
        while true {
            try Task.checkCancellation()
            let now = deviceNowMilliseconds()
            let transition = try core.deviceAuthorizationTransition(
                GitHubDeviceTransitionRequest(
                    event: event,
                    expiresIn: authorization.expiresIn,
                    interval: interval,
                    elapsedMilliseconds: now >= started ? now - started : 0,
                    suggestedInterval: result?.interval
                )
            )
            interval = transition.intervalSeconds
            switch transition.action {
            case "wait":
                try await deviceSleep(transition.waitMilliseconds)
                event = "tick"
            case "poll":
                let response = try await perform(
                    GitHubRequest(operation: "deviceToken", clientID: clientID, deviceCode: authorization.deviceCode),
                    token: nil
                )
                guard case .deviceToken(let next) = response else { throw ServiceError.invalidResponse }
                result = next
                event = next.status
            case "authorize":
                guard let accessToken = result?.accessToken, !accessToken.isEmpty else {
                    throw ServiceError.invalidResponse
                }
                return try await saveAndValidate(accessToken)
            case "expired":
                throw ServiceError.authorizationExpired
            case "denied":
                throw ServiceError.authorizationDenied
            default:
                throw ServiceError.authorizationFailed(result?.message ?? result?.error ?? L10n.string("Unknown error"))
            }
        }
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

    func resolvePullRequestBranchDefaults(
        at workspaceURL: URL?
    ) throws -> GitHubPullRequestBranchDefaults {
        guard let workspaceURL else { throw ServiceError.noWorkspace }
        return try git.pullRequestBranchDefaults(at: workspaceURL)
    }

    func publishPullRequestBranch(named name: String, at workspaceURL: URL?) throws {
        guard let workspaceURL else { throw ServiceError.noWorkspace }
        try git.publishPullRequestBranch(named: name, at: workspaceURL)
    }

    func listPullRequests(repository: GitHubRepository, state: String = "open") async throws -> [GitHubPullRequest] {
        let response = try await perform(
            GitHubRequest(operation: "listPullRequests", repository: repository, state: state)
        )
        guard case .pullRequests(let requests) = response else { throw ServiceError.invalidResponse }
        return requests
    }

    func listBranches(repository: GitHubRepository) async throws -> [GitHubBranch] {
        let response = try await perform(
            GitHubRequest(operation: "listBranches", repository: repository)
        )
        guard case .branches(let branches) = response else { throw ServiceError.invalidResponse }
        return branches
    }

    func compareBranches(
        repository: GitHubRepository,
        base: String,
        head: String
    ) async throws -> GitHubComparison {
        let response = try await perform(GitHubRequest(
            operation: "compareBranches",
            repository: repository,
            head: head,
            base: base
        ))
        guard case .comparison(let comparison) = response else {
            throw ServiceError.invalidResponse
        }
        return comparison
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

    func checkoutPreview(_ pullRequest: GitHubPullRequest, repository: GitHubRepository, at workspaceURL: URL?) throws -> GitHubCheckoutIntent {
        guard let workspaceURL else { throw ServiceError.noWorkspace }
        let preview = try git.previewCheckout(pullRequest, repository: repository, at: workspaceURL)
        return GitHubCheckoutIntent(workspaceURL: workspaceURL, request: pullRequest, repository: repository, preview: preview)
    }

    func checkout(_ intent: GitHubCheckoutIntent) throws {
        try git.checkoutPullRequest(intent.request, repository: intent.repository, at: intent.workspaceURL, preview: intent.preview)
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
