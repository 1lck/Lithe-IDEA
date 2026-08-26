import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

private struct GitHubCoreStub: GitHubCorePlanning {
    func parseRemote(_ remoteURL: String) throws -> GitHubRepository {
        #expect(remoteURL == "git@github.com:openai/codex.git")
        return GitHubRepository(owner: "openai", name: "codex")
    }

    func requestPlan(_ request: GitHubRequest) throws -> GitHubRequestPlan {
        if request.operation == "listBranches" {
            return GitHubRequestPlan(
                host: .api,
                method: "GET",
                path: "/repos/openai/codex/branches",
                query: ["per_page": "100"],
                body: nil,
                requiresAuthentication: true
            )
        }
        if request.operation == "compareBranches" {
            return GitHubRequestPlan(
                host: .api,
                method: "GET",
                path: "/repos/openai/codex/compare/main...feature%2Fcurrent",
                query: [:],
                body: nil,
                requiresAuthentication: true
            )
        }
        if ["getPullRequest", "listPullRequestFiles", "listPullRequestComments"]
            .contains(request.operation), let pullNumber = request.pullNumber {
            return GitHubRequestPlan(
                host: .api,
                method: "GET",
                path: "/test/\(request.operation)/\(pullNumber)",
                query: [:],
                body: nil,
                requiresAuthentication: true
            )
        }
        return GitHubRequestPlan(
            host: .api,
            method: "GET",
            path: "/user",
            query: [:],
            body: nil,
            requiresAuthentication: request.operation == "currentUser"
        )
    }

    func normalizeResponse(
        operation: String,
        status: Int,
        body: String
    ) throws -> GitHubNormalizedResponse {
        #expect(status == 200)
        if operation == "getPullRequest" {
            return .pullRequest(try Self.pullRequest(number: Self.pullNumber(from: body)))
        }
        if operation == "listPullRequestFiles" {
            let number = Self.pullNumber(from: body)
            return .files([GitHubPullRequestFile(
                path: "pull-request-\(number).swift",
                status: "modified",
                additions: number,
                deletions: 0,
                patch: nil
            )])
        }
        if operation == "listPullRequestComments" {
            return .comments([try Self.comment(number: Self.pullNumber(from: body))])
        }
        #expect(body == "user-response")
        if operation == "listBranches" {
            return .branches([
                GitHubBranch(name: "alpha"),
                GitHubBranch(name: "main")
            ])
        }
        if operation == "compareBranches" {
            return .comparison(GitHubComparison(
                commits: [GitHubComparisonCommit(sha: "abc123", message: "Add PR generation")],
                files: [GitHubPullRequestFile(
                    path: "Sources/PullRequest.swift",
                    status: "modified",
                    additions: 2,
                    deletions: 1,
                    patch: "@@ -1 +1 @@\n-old\n+new"
                )]
            ))
        }
        if operation == "listPullRequests" {
            return .pullRequests([])
        }
        return .user(GitHubUser(
            login: "octocat",
            url: "https://github.com/octocat",
            avatarURL: nil
        ))
    }

    private static func pullNumber(from body: String) -> UInt64 {
        UInt64(body.split(separator: "/").last ?? "") ?? 0
    }

    private static func pullRequest(number: UInt64) throws -> GitHubPullRequest {
        let data = Data("""
        {
          "number": \(number),
          "title": "Pull request \(number)",
          "body": "",
          "state": "open",
          "isDraft": false,
          "url": "https://github.com/openai/codex/pull/\(number)",
          "author": { "login": "octocat", "url": "https://github.com/octocat", "avatarUrl": null },
          "headRef": "feature/\(number)",
          "headRepository": "openai/codex",
          "baseRef": "main",
          "baseRepository": "openai/codex",
          "createdAt": "2026-08-19T00:00:00Z",
          "updatedAt": "2026-08-19T00:00:00Z",
          "isMerged": false,
          "isMergeable": true,
          "additions": 1,
          "deletions": 0,
          "changedFiles": 1,
          "commentsCount": 1,
          "labels": [],
          "assignees": []
        }
        """.utf8)
        return try JSONDecoder().decode(GitHubPullRequest.self, from: data)
    }

    private static func comment(number: UInt64) throws -> GitHubComment {
        let data = Data("""
        {
          "id": \(number),
          "author": { "login": "octocat", "url": "https://github.com/octocat", "avatarUrl": null },
          "body": "Comment \(number)",
          "createdAt": "2026-08-19T00:00:00Z",
          "updatedAt": "2026-08-19T00:00:00Z",
          "url": "https://github.com/openai/codex/pull/\(number)#comment"
        }
        """.utf8)
        return try JSONDecoder().decode(GitHubComment.self, from: data)
    }
}

private actor GitHubTransportStub: GitHubHTTPTransport {
    private(set) var receivedToken: String?
    private(set) var branchRequestCount = 0
    private let branchRequestDelay: Duration?
    private let pullRequestDelays: [UInt64: Duration]

    init(
        branchRequestDelay: Duration? = nil,
        pullRequestDelays: [UInt64: Duration] = [:]
    ) {
        self.branchRequestDelay = branchRequestDelay
        self.pullRequestDelays = pullRequestDelays
    }

    func execute(plan: GitHubRequestPlan, token: String?) async throws -> GitHubHTTPResponse {
        receivedToken = token
        if plan.path.hasSuffix("/branches") {
            branchRequestCount += 1
            if let branchRequestDelay {
                try await Task.sleep(for: branchRequestDelay)
            }
        }
        if let pullNumber = UInt64(plan.path.split(separator: "/").last ?? ""),
           let delay = pullRequestDelays[pullNumber] {
            try await Task.sleep(for: delay)
        }
        if plan.path.hasPrefix("/test/") {
            return GitHubHTTPResponse(status: 200, body: plan.path)
        }
        return GitHubHTTPResponse(status: 200, body: "user-response")
    }
}

private struct GitHubConfigurationStub: GitHubConfiguration {
    let oauthClientID: String? = nil
}

private final class GitHubSecureStoreStub: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(key: String) -> String? {
        lock.withLock { values[key] }
    }

    func write(_ value: String, key: String) throws {
        lock.withLock { values[key] = value }
    }

    func delete(key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

private struct GitHubGitStub: GitHubGitOperations {
    func originRemote(at workspaceURL: URL) throws -> String {
        "git@github.com:openai/codex.git"
    }

    func pullRequestBranchDefaults(at workspaceURL: URL) throws -> GitHubPullRequestBranchDefaults {
        GitHubPullRequestBranchDefaults(head: "feature/current", base: "develop")
    }

    func publishPullRequestBranch(named name: String, at workspaceURL: URL) throws {}

    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, at workspaceURL: URL) throws {}
}

@Suite("GitHub service")
struct GitHubServiceTests {
    @Test("Branch comparison provides grounded AI generation input")
    @MainActor
    func pullRequestDescriptionInput() async throws {
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: GitHubTransportStub(),
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )
        _ = try await service.connect(personalAccessToken: "fake-test-token")
        let model = GitHubFeatureModel(service: service)
        await model.restore(workspaceURL: URL(fileURLWithPath: "/tmp/lithe-github-fixture"))

        let input = try await model.pullRequestDescriptionInput(
            base: "main",
            head: "feature/current"
        )

        #expect(input.repository == "openai/codex")
        #expect(input.base == "main")
        #expect(input.head == "feature/current")
        #expect(input.commitMessages == ["Add PR generation"])
        #expect(input.files.first?.path == "Sources/PullRequest.swift")
    }

    @Test("Branch choices are loaded through the GitHub service")
    func branchResolution() async throws {
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: GitHubTransportStub(),
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )
        _ = try await service.connect(personalAccessToken: "fake-test-token")

        let branches = try await service.listBranches(
            repository: GitHubRepository(owner: "openai", name: "codex")
        )

        #expect(branches.map(\.name) == ["alpha", "main"])
    }

    @Test("Branch choices reuse fresh cached results")
    @MainActor
    func branchCache() async throws {
        let transport = GitHubTransportStub()
        var now = Date(timeIntervalSince1970: 1_000)
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: transport,
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )
        _ = try await service.connect(personalAccessToken: "fake-test-token")
        let model = GitHubFeatureModel(service: service, currentDate: { now })
        await model.restore(workspaceURL: URL(fileURLWithPath: "/tmp/lithe-github-fixture"))

        await model.loadBranches()
        await model.loadBranches()
        #expect(await transport.branchRequestCount == 1)

        now.addTimeInterval(61)
        await model.loadBranches()
        #expect(await transport.branchRequestCount == 2)
    }

    @Test("Concurrent branch loads share one request")
    @MainActor
    func concurrentBranchLoads() async throws {
        let transport = GitHubTransportStub(branchRequestDelay: .milliseconds(50))
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: transport,
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )
        _ = try await service.connect(personalAccessToken: "fake-test-token")
        let model = GitHubFeatureModel(service: service)
        await model.restore(workspaceURL: URL(fileURLWithPath: "/tmp/lithe-github-fixture"))

        async let first: Void = model.loadBranches(force: true)
        async let second: Void = model.loadBranches(force: true)
        _ = await (first, second)

        #expect(await transport.branchRequestCount == 1)
    }

    @Test("A stale pull request selection cannot overwrite a newer selection")
    @MainActor
    func stalePullRequestSelectionIsDiscarded() async throws {
        let transport = GitHubTransportStub(pullRequestDelays: [1: .milliseconds(100)])
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: transport,
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )
        let model = GitHubFeatureModel(service: service)
        await model.connect(
            personalAccessToken: "fake-test-token",
            workspaceURL: URL(fileURLWithPath: "/tmp/lithe-github-fixture")
        )

        let staleSelection = Task { @MainActor in await model.selectPullRequest(number: 1) }
        try await Task.sleep(for: .milliseconds(10))
        let currentSelection = Task { @MainActor in await model.selectPullRequest(number: 2) }
        _ = await (staleSelection.value, currentSelection.value)

        #expect(model.selectedPullRequest?.number == 2)
        #expect(model.files.map(\.path) == ["pull-request-2.swift"])
        #expect(model.comments.map(\.body) == ["Comment 2"])
        #expect(model.contentState == .ready)
    }

    @Test("Creating a pull request uses the GitHub workspace instead of a modal")
    @MainActor
    func createWorkspacePresentationState() {
        let model = GitHubFeatureModel(service: GitHubService(
            core: GitHubCoreStub(),
            transport: GitHubTransportStub(),
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        ))

        model.beginCreatingPullRequest()
        #expect(model.isCreatingPullRequest)

        model.cancelCreatingPullRequest()
        #expect(!model.isCreatingPullRequest)
    }

    @Test("Swift bridge encodes the GitHub remote URL using the shared contract")
    func productionBridgeParsesGitHubRemote() throws {
        let bridge = RustCoreBridge()
        guard bridge.isAvailable else { return }
        let repository = try RustGitHubCore(bridge: bridge)
            .parseRemote("https://github.com/example/lithe.git")

        #expect(repository.owner == "example")
        #expect(repository.name == "lithe")
    }

    @Test("Product configuration includes the public GitHub OAuth client ID")
    func productClientConfiguration() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let values = try #require(propertyList as? [String: Any])
        let clientID = try #require(values["LitheGitHubOAuthClientID"] as? String)

        #expect(!clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Development configuration can override the product GitHub OAuth client ID")
    func developmentClientConfiguration() {
        let configuration = MacGitHubConfiguration(
            bundle: .main,
            environment: ["LITHE_GITHUB_CLIENT_ID": "fake-development-client"]
        )

        #expect(configuration.oauthClientID == "fake-development-client")
    }

    @Test("A manually supplied token is validated before Keychain persistence")
    func tokenValidationAndPersistence() async throws {
        let transport = GitHubTransportStub()
        let store = GitHubSecureStoreStub()
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: transport,
            configuration: GitHubConfigurationStub(),
            secureStore: store,
            git: GitHubGitStub()
        )

        let user = try await service.connect(personalAccessToken: "  github_pat_fake  ")

        #expect(user.login == "octocat")
        #expect(await transport.receivedToken == "github_pat_fake")
        #expect(store.read(key: "oauth-token") == "github_pat_fake")
    }

    @Test("Repository identity is resolved through the shared Core parser")
    func repositoryResolution() async throws {
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: GitHubTransportStub(),
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )

        let repository = try await service.resolveRepository(
            at: URL(fileURLWithPath: "/tmp/lithe-github-fixture")
        )

        #expect(repository.fullName == "openai/codex")
    }

    @Test("Pull request branch defaults come from the checked-out Git workspace")
    func pullRequestBranchDefaults() async throws {
        let service = GitHubService(
            core: GitHubCoreStub(),
            transport: GitHubTransportStub(),
            configuration: GitHubConfigurationStub(),
            secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub()
        )

        let defaults = try await service.resolvePullRequestBranchDefaults(
            at: URL(fileURLWithPath: "/tmp/lithe-github-fixture")
        )

        #expect(defaults.head == "feature/current")
        #expect(defaults.base == "develop")
    }
}
