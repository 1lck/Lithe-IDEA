import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Agent subscription accounts")
struct AgentAccountTests {
    private func settings(_ store: AccountSettingsStore = AccountSettingsStore()) -> AppSettings {
        AppSettings(store: store)
    }

    private func window(_ used: Double, resetsIn seconds: Double, limit: UInt64, now: Date) -> AgentSubscriptionQuota.Window {
        .init(id: "w", name: "claude", limitSeconds: limit, usedPercent: used,
              resetsAt: Int64(now.timeIntervalSince1970 + seconds))
    }

    @Test func paceComparesUsedShareWithElapsedShare() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Half of a 10 hour window elapsed while 30% was used: 20 points under pace.
        let slow = window(30, resetsIn: 5 * 3_600, limit: 10 * 3_600, now: now)
        #expect(abs((AgentAccountUsagePresentation.pace(slow, now: now) ?? 0) + 20) < 0.001)
        let fast = window(80, resetsIn: 5 * 3_600, limit: 10 * 3_600, now: now)
        #expect(abs((AgentAccountUsagePresentation.pace(fast, now: now) ?? 0) - 30) < 0.001)
        // A window that already reset has no meaningful pace.
        let expired = window(80, resetsIn: -1, limit: 10 * 3_600, now: now)
        #expect(AgentAccountUsagePresentation.pace(expired, now: now) == nil)
    }

    @Test func accountsRoundTripAsPathsOnlyAndMapDirectoriesToKeys() throws {
        let store = AccountSettingsStore()
        let first = settings(store)
        let profile = AgentAccountProfile(id: UUID(), agentID: "claude-acp", name: "Work", directoryPath: "/tmp/lithe-test-account")
        first.agentAccounts = [profile]
        first.preferredAgentAccountIDs["claude-acp"] = profile.id
        let reloaded = settings(store)
        #expect(reloaded.agentAccounts == [profile])
        #expect(reloaded.preferredAgentAccountDirectory(for: "claude-acp")?.path == "/tmp/lithe-test-account")
        // Another Agent never sees this account.
        #expect(reloaded.preferredAgentAccountDirectory(for: "codex-acp") == nil)
        #expect(reloaded.agentAccountKey(agentID: "claude-acp", directory: profile.directoryURL) == "claude-acp:\(profile.id.uuidString)")
        #expect(reloaded.agentAccountKey(agentID: "claude-acp", directory: nil) == AppSettings.defaultAgentAccountKey("claude-acp"))
        let stored = String(decoding: try #require(store.data(forKey: "settings.agentAccounts")), as: UTF8.self)
        #expect(!stored.lowercased().contains("token"))
    }

    @Test func observationsAreKeptPerAccountAndKeepLastKnownValues() {
        let value = settings()
        let profile = AgentAccountProfile(id: UUID(), agentID: "claude-acp", name: "Work", directoryPath: "/tmp/lithe-test-account")
        value.agentAccounts = [profile]
        let quota = AgentSubscriptionQuota(windows: [], fetchedAt: 100, source: .claude)
        value.recordAgentAccount(agentID: "claude-acp", directory: profile.directoryURL, email: "a@example.test", plan: "Pro", quota: quota)
        value.recordAgentAccount(agentID: "claude-acp", directory: nil, email: "b@example.test", plan: nil, quota: nil)
        // A later report without a plan must not erase the last known plan.
        value.recordAgentAccount(agentID: "claude-acp", directory: profile.directoryURL, email: "a@example.test", plan: nil, quota: nil)
        let key = "claude-acp:\(profile.id.uuidString)"
        #expect(value.agentAccountSnapshots[key]?.plan == "Pro")
        #expect(value.agentAccountSnapshots[key]?.quota == quota)
        #expect(value.agentAccountSnapshots[AppSettings.defaultAgentAccountKey("claude-acp")]?.email == "b@example.test")
    }

    @Test func eachSubscriptionReceivesOnlyItsOwnAccountDirectory() throws {
        let value = settings()
        let claude = AgentAccountProfile(id: UUID(), agentID: "claude-acp", name: "Work", directoryPath: "/tmp/lithe-test-claude")
        let codex = AgentAccountProfile(id: UUID(), agentID: "codex-acp", name: "Work", directoryPath: "/tmp/lithe-test-codex")
        value.agentAccounts = [claude, codex]
        value.preferredAgentAccountIDs = ["claude-acp": claude.id]
        value.agentConfigurations["claude-acp"] = AgentConfiguration(name: "Claude", providerID: nil, authentication: .claudeSubscription)
        value.agentConfigurations["codex-acp"] = AgentConfiguration(name: "Codex", providerID: nil, authentication: .codexSubscription)
        let resolver = AgentLaunchConfigurationResolver(settings: value, configurationSources: [], credentialResolver: NoCredentials())
        let workspace = URL(fileURLWithPath: "/tmp/lithe-test-workspace")
        func directories() throws -> (claude: URL?, codex: URL?) {
            (try resolver.resolve(agentID: "claude-acp", workspaceURL: workspace, dataDirectory: workspace).accountDirectory,
             try resolver.resolve(agentID: "codex-acp", workspaceURL: workspace, dataDirectory: workspace).accountDirectory)
        }
        var launched = try directories()
        #expect(launched.claude?.path == "/tmp/lithe-test-claude")
        #expect(launched.codex == nil)
        value.preferredAgentAccountIDs["codex-acp"] = codex.id
        launched = try directories()
        #expect(launched.codex?.path == "/tmp/lithe-test-codex")
        // A preference pointing at another Agent's account is ignored.
        value.preferredAgentAccountIDs["codex-acp"] = claude.id
        #expect(try directories().codex == nil)
    }
}

private struct NoCredentials: AIProviderCredentialResolver {
    func readAPIKey(for provider: AIProviderProfile) -> String? { nil }
}

private final class AccountSettingsStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
