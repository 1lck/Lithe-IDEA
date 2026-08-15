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
        GitHubRequestPlan(
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
        #expect(body == "user-response")
        return .user(GitHubUser(
            login: "octocat",
            url: "https://github.com/octocat",
            avatarURL: nil
        ))
    }
}

private actor GitHubTransportStub: GitHubHTTPTransport {
    private(set) var receivedToken: String?

    func execute(plan: GitHubRequestPlan, token: String?) async throws -> GitHubHTTPResponse {
        receivedToken = token
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

    func checkoutPullRequest(_ pullRequest: GitHubPullRequest, at workspaceURL: URL) throws {}
}

@Suite("GitHub service")
struct GitHubServiceTests {
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
}
