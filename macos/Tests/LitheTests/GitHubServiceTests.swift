import Foundation
import Testing
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

private struct GitHubCoreStub: GitHubCorePlanning {
    func deviceAuthorizationTransition(_ request: GitHubDeviceTransitionRequest) throws -> GitHubDeviceTransition {
        throw GitHubService.ServiceError.invalidResponse
    }
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

    static func pullRequest(number: UInt64) throws -> GitHubPullRequest {
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

private struct GitHubDeviceConfigurationStub: GitHubConfiguration {
    let oauthClientID: String? = "fixture-client"
}

private final class DeviceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 0
    private var delays: [UInt64] = []

    func now() -> UInt64 { lock.withLock { time } }
    func advance(_ milliseconds: UInt64) throws {
        try Task.checkCancellation()
        lock.withLock { time += milliseconds; delays.append(milliseconds) }
    }
    var observedDelays: [UInt64] { lock.withLock { delays } }
}

private actor DeviceTestTransport: GitHubHTTPTransport {
    private var responses: [String]
    private let expiresIn: UInt64
    private(set) var pollCount = 0
    init(responses: [String], expiresIn: UInt64 = 120) {
        self.responses = responses
        self.expiresIn = expiresIn
    }

    func execute(plan: GitHubRequestPlan, token: String?) async throws -> GitHubHTTPResponse {
        if plan.path == "/login/device/code" {
            return GitHubHTTPResponse(status: 200, body:
                #"{"device_code":"fixture-code","user_code":"ABCD","verification_uri":"https://example.invalid","expires_in":\#(expiresIn),"interval":5}"#)
        }
        if plan.path == "/login/oauth/access_token" {
            pollCount += 1
            guard !responses.isEmpty else { throw GitHubService.ServiceError.invalidResponse }
            return GitHubHTTPResponse(status: 200, body: responses.removeFirst())
        }
        guard plan.path == "/user", token == "fixture-token" else {
            throw GitHubService.ServiceError.invalidResponse
        }
        return GitHubHTTPResponse(status: 200, body: #"{"login":"fixture-user"}"#)
    }
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

    func previewCheckout(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL) throws -> GitHubCheckoutPreview {
        throw GitHubService.ServiceError.invalidResponse
    }
    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL, preview: GitHubCheckoutPreview) throws {}
}

private final class GitHubCheckoutGitStub: GitHubGitOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var checkoutCount: Int { lock.withLock { count } }

    func originRemote(at workspaceURL: URL) throws -> String { "git@github.com:openai/codex.git" }
    func pullRequestBranchDefaults(at workspaceURL: URL) throws -> GitHubPullRequestBranchDefaults {
        GitHubPullRequestBranchDefaults(head: "feature/current", base: "main")
    }
    func publishPullRequestBranch(named name: String, at workspaceURL: URL) throws {}
    func previewCheckout(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL) throws -> GitHubCheckoutPreview {
        try JSONDecoder().decode(GitHubCheckoutPreview.self, from: Data(
            #"{"plan":{"allowed":true,"branch":"pr/1-feature-1","conflict":null,"actions":["fetchPullRequest","createBranch"]},"head":"fixture","currentBranch":"refs/heads/main","originFingerprint":"fixture"}"#.utf8
        ))
    }
    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, repository: GitHubRepository?, at workspaceURL: URL, preview: GitHubCheckoutPreview) throws {
        lock.withLock { count += 1 }
    }
}

@Suite("GitHub service")
struct GitHubServiceTests {
    @Test("PR checkout confirmation cannot follow a different selection or workspace")
    @MainActor
    func checkoutConfirmationRejectsChangedSelectionAndWorkspace() async throws {
        let git = GitHubCheckoutGitStub()
        let service = GitHubService(core: GitHubCoreStub(), transport: GitHubTransportStub(),
                                    configuration: GitHubConfigurationStub(), secureStore: GitHubSecureStoreStub(), git: git)
        let model = GitHubFeatureModel(service: service)
        let root = URL(fileURLWithPath: "/tmp/lithe-github-fixture")
        await model.connect(personalAccessToken: "fixture-access", workspaceURL: root)
        await model.selectPullRequest(number: 1)
        let first = try #require(await model.prepareCheckout(workspaceURL: root))
        let otherRoot = URL(fileURLWithPath: "/tmp/another-github-fixture")
        #expect(await model.checkout(first, workspaceURL: otherRoot) == false)
        #expect(git.checkoutCount == 0)
        let second = try #require(await model.prepareCheckout(workspaceURL: root))
        await model.selectPullRequest(number: 2)
        #expect(await model.checkout(second, workspaceURL: root) == false)
        #expect(git.checkoutCount == 0)
    }

    @Test("PR checkout preserves an existing local branch",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func checkoutDoesNotResetExistingBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-pr-checkout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) async throws -> String {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                                                   arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0, "git \(arguments) failed")
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "--template=", "-q"])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "--no-gpg-sign", "-qm", "first"])
        _ = try await git(["branch", "pr/42-feature-42"])
        let original = try await git(["rev-parse", "refs/heads/pr/42-feature-42"])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "--no-gpg-sign", "-qm", "second"])
        _ = try await git(["init", "--bare", "--template=", "-q", root.appendingPathComponent("remote.git").path])
        _ = try await git(["remote", "add", "origin", root.appendingPathComponent("remote.git").path])
        _ = try await git(["push", "-q", "origin", "HEAD:refs/pull/42/head"])

        let operations = MacGitHubGitOperations(core: RustCoreBridge())
        let request = try GitHubCoreStub.pullRequest(number: 42)
        do {
            _ = try operations.previewCheckout(request, repository: nil, at: root)
            Issue.record("An existing branch was not reported during preview")
        } catch {
            #expect(error.localizedDescription == L10n.string("The pull request branch already exists. Rename or remove it before retrying."))
        }
        _ = try await git(["branch", "-D", "pr/42-feature-42"])
        let preview = try operations.previewCheckout(request, repository: nil, at: root)
        _ = try await git(["branch", "pr/42-feature-42", original])
        do {
            try operations.checkoutPullRequest(request, repository: nil, at: root, preview: preview)
            Issue.record("Existing branch was reset by PR checkout")
        } catch {
            // A branch collision must be reported rather than replacing its commit.
            #expect(error.localizedDescription == L10n.string("The pull request branch already exists. Rename or remove it before retrying."))
        }
        #expect(try await git(["rev-parse", "refs/heads/pr/42-feature-42"]) == original)

        _ = try await git(["branch", "-D", "pr/42-feature-42"])
        let reviewed = try operations.previewCheckout(request, repository: nil, at: root)
        #expect(reviewed.plan.allowed)
        #expect(reviewed.plan.actions == ["fetchPullRequest", "createBranch"])
        let remoteHead = try await git(["rev-parse", "HEAD"])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "--no-gpg-sign", "-qm", "changed after review"])
        do {
            try operations.checkoutPullRequest(request, repository: nil, at: root, preview: reviewed)
            Issue.record("A stale checkout preview unexpectedly succeeded")
        } catch {
            // The selected checkout changed after the user reviewed it.
            #expect(error.localizedDescription == L10n.string("The checkout or origin remote changed. Review the pull request checkout again."))
        }
        let fresh = try operations.previewCheckout(request, repository: nil, at: root)
        try operations.checkoutPullRequest(request, repository: nil, at: root, preview: fresh)
        #expect(try await git(["branch", "--show-current"]) == "pr/42-feature-42")
        #expect(try await git(["rev-parse", "HEAD"]) == remoteHead)
    }

    @Test("Swift bridge consumes the shared pull-request checkout fixture",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func checkoutPlanFixture() throws {
        struct Request: Codable { let number: UInt64; let headRef: String; let branchExists: Bool }
        struct Fixture: Decodable {
            struct Case: Decodable { let name: String; let request: Request; let expected: GitHubCheckoutPreview.Plan }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared/fixtures/github/pr-checkout-plan-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let core = RustCoreBridge()
        for item in fixture.cases {
            let result: GitHubCheckoutPreview.Plan = try core.executeResult(
                command: "github.pullRequestCheckoutPlan", payload: item.request
            ).get()
            #expect(result == item.expected, "\(item.name)")
        }
    }

    @Test("Swift bridge consumes the shared device-flow fixture",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func deviceTransitionFixture() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                let name: String
                let request: GitHubDeviceTransitionRequest
                let expected: GitHubDeviceTransition
            }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("shared/fixtures/github/device-authorization-transition-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let core = RustGitHubCore(bridge: RustCoreBridge())
        for item in fixture.cases {
            #expect(try core.deviceAuthorizationTransition(item.request) == item.expected, "\(item.name)")
        }
    }

    @Test("Device flow waits for each shared transition and validates the authorized user",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func deviceFlowSlowDown() async throws {
        let clock = DeviceTestClock()
        let transport = DeviceTestTransport(responses: [
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down"}"#,
            #"{"access_token":"fixture-token"}"#
        ])
        let service = GitHubService(
            core: RustGitHubCore(bridge: RustCoreBridge()), transport: transport,
            configuration: GitHubDeviceConfigurationStub(), secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub(), deviceNowMilliseconds: { clock.now() },
            deviceSleep: { try clock.advance($0) }
        )
        let authorization = try await service.startDeviceAuthorization()
        let user = try await service.finishDeviceAuthorization(authorization)
        #expect(user.login == "fixture-user")
        #expect(clock.observedDelays == [5_000, 5_000, 10_000])
        #expect(await transport.pollCount == 3)
    }

    @Test("Device flow never polls after the local deadline",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func deviceFlowDeadline() async throws {
        let clock = DeviceTestClock()
        let transport = DeviceTestTransport(responses: [], expiresIn: 2)
        let service = GitHubService(
            core: RustGitHubCore(bridge: RustCoreBridge()), transport: transport,
            configuration: GitHubDeviceConfigurationStub(), secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub(), deviceNowMilliseconds: { clock.now() },
            deviceSleep: { try clock.advance($0) }
        )
        let authorization = try await service.startDeviceAuthorization()
        do {
            _ = try await service.finishDeviceAuthorization(authorization)
            Issue.record("Expired authorization unexpectedly succeeded")
        } catch GitHubService.ServiceError.authorizationExpired {
            #expect(clock.observedDelays == [2_000])
            #expect(await transport.pollCount == 0)
        }
    }

    @Test("Time spent displaying the device code counts toward expiration",
          .enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func deviceFlowDisplayedTooLong() async throws {
        let clock = DeviceTestClock()
        let transport = DeviceTestTransport(responses: [], expiresIn: 2)
        let service = GitHubService(
            core: RustGitHubCore(bridge: RustCoreBridge()), transport: transport,
            configuration: GitHubDeviceConfigurationStub(), secureStore: GitHubSecureStoreStub(),
            git: GitHubGitStub(), deviceNowMilliseconds: { clock.now() },
            deviceSleep: { try clock.advance($0) }
        )
        let authorization = try await service.startDeviceAuthorization()
        try clock.advance(2_000)
        do {
            _ = try await service.finishDeviceAuthorization(authorization)
            Issue.record("An expired device authorization unexpectedly succeeded")
        } catch GitHubService.ServiceError.authorizationExpired {
            #expect(clock.observedDelays == [2_000])
            #expect(await transport.pollCount == 0)
        }
    }

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
