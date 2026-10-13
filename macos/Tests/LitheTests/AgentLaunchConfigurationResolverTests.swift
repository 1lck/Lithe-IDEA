import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Agent launch configuration resolution")
struct AgentLaunchConfigurationResolverTests {
    @Test(arguments: [AIConfigurationSourceKind.codex, .claude], [false, true])
    func cliSwitchUsesOneCompleteSnapshotAndPreservesSelections(source: AIConfigurationSourceKind, noCommitSelection: Bool) throws {
        let store = LaunchSettingsStore()
        let settings = AppSettings(store: store)
        let imported = settings.importAIConfiguration(snapshot(source, revision: "old"))
        settings.setAgentProvider(imported.id, for: agentID(source), name: source.title)
        settings.updateAIProvider(imported.id) { $0.allowsInsecureHTTP = true }
        let otherSource: AIConfigurationSourceKind = source == .codex ? .claude : .codex
        let other = settings.importAIConfiguration(snapshot(otherSource, revision: "other"))
        settings.setAgentProvider(other.id, for: agentID(otherSource), name: otherSource.title)
        let manual = AIProviderProfile(name: "Manual", endpoint: "https://manual.example.test/v1",
            model: "manual-model", apiProtocol: .responses)
        settings.commitMessageAI.providers.append(manual)
        settings.commitMessageAI.activeProviderID = noCommitSelection ? nil : manual.id
        let bindings = settings.agentConfigurations
        let current = snapshot(source, revision: "current")
        let next = snapshot(source, revision: "next")
        // A second read would observe another CLI switch. Every route/key pair must
        // come from one read, and the following connection must see the newer pair.
        let cli = LaunchConfigurationSource(snapshots: [current, next])
        let keys = LaunchCredentialResolver(key: "must-not-use-this-key")
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [cli], credentialResolver: keys)

        for (read, expected) in [current, next].enumerated() {
            let launch = try resolve(resolver, agentID: agentID(source))
            #expect(launch.providerEndpoint == expected.endpoint)
            #expect(launch.apiKey == expected.apiKey)
            #expect(launch.model == expected.model)
            #expect(launch.providerProtocol == expected.apiProtocol.rawValue)
            #expect(launch.providerName == "\(source.title) · \(expected.providerName)")
            #expect(launch.allowsInsecureHTTP)
            #expect(cli.loadCount == read + 1)
            #expect(cli.modelLoadCount == 0)
            #expect(keys.readCount == 0)
            let saved = try #require(settings.agentProvider(for: agentID(source)))
            #expect(saved.id == imported.id)
            #expect(saved.endpoint == expected.endpoint)
            #expect(saved.model == expected.model)
            #expect(saved.authentication == expected.authentication)
            #expect(saved.requiresAPIKey == expected.requiresAPIKey)
            #expect(settings.agentConfigurations == bindings)
            #expect(settings.commitMessageAI.activeProviderID == (noCommitSelection ? nil : manual.id))
            #expect(settings.agentProvider(for: agentID(otherSource)) == other)
            #expect(settings.commitMessageAI.providers.last == manual)
            let reloaded = AppSettings(store: store)
            #expect(reloaded.agentConfigurations == bindings)
            #expect(reloaded.commitMessageAI == settings.commitMessageAI)
        }
        let persisted = String(decoding: try #require(store.data(forKey: "settings.commitMessageAI")), as: UTF8.self)
        #expect(!persisted.contains("fixture-key"))
        #expect(!persisted.contains("must-not-use-this-key"))
    }

    @Test(arguments: [AIConfigurationSourceKind.codex, .claude])
    func missingKeyRefreshesMetadataAndNeverFallsBackToSavedCredentials(source: AIConfigurationSourceKind) throws {
        let settings = AppSettings(store: LaunchSettingsStore())
        let imported = settings.importAIConfiguration(snapshot(source, revision: "old"))
        settings.setAgentProvider(imported.id, for: agentID(source), name: source.title)
        let current = snapshot(source, revision: "current", key: " \n")
        let cli = LaunchConfigurationSource(snapshots: [current])
        let keys = LaunchCredentialResolver(key: "stale-fixture-key")
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [cli], credentialResolver: keys)
        #expect(throws: AgentConversationError.missingAPIKey) { try resolve(resolver, agentID: agentID(source)) }
        #expect(settings.agentProvider(for: agentID(source))?.endpoint == current.endpoint)
        #expect(settings.agentProvider(for: agentID(source))?.model == current.model)
        #expect(cli.loadCount == 1)
        #expect(keys.readCount == 0)
    }

    @Test(arguments: [false, true])
    func missingOrDifferentSourceCannotLaunchTheStaleRoute(differentSource: Bool) {
        let settings = AppSettings(store: LaunchSettingsStore())
        let imported = settings.importAIConfiguration(snapshot(.codex, revision: "old"))
        settings.setAgentProvider(imported.id, for: "codex-acp", name: "Codex")
        let cli = LaunchConfigurationSource(snapshots: differentSource ? [snapshot(.claude, revision: "other")] : [],
            model: .init(source: .codex, model: "current-cli-default"))
        let keys = LaunchCredentialResolver(key: "stale-fixture-key")
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [cli], credentialResolver: keys)
        #expect(throws: AgentConversationError.missingProvider) { try resolve(resolver, agentID: "codex-acp") }
        #expect(settings.agentProvider(for: "codex-acp")?.model == "current-cli-default")
        #expect(settings.agentProvider(for: "codex-acp")?.id == imported.id)
        #expect(keys.readCount == 0)
    }

    @Test
    func manualProviderKeepsItsRouteAndCustomCommandWithoutReadingCLI() throws {
        let settings = AppSettings(store: LaunchSettingsStore())
        let manual = AIProviderProfile(name: "Manual", endpoint: "https://manual.example.test/v1",
            model: "manual-model", apiProtocol: .responses)
        settings.commitMessageAI.providers = [manual]
        settings.setAgentProvider(manual.id, for: AgentConfiguration.customAgentID, name: "Custom")
        settings.agentCommand = " fixture-agent "
        settings.agentArguments = " --first \n\n literal argument \n"
        let cli = LaunchConfigurationSource(snapshots: [snapshot(.codex, revision: "other")])
        let keys = LaunchCredentialResolver(key: " manual-fixture-key \n")
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [cli], credentialResolver: keys)
        let launch = try resolve(resolver, agentID: AgentConfiguration.customAgentID)
        #expect(launch.agentID == nil)
        #expect(launch.command == "fixture-agent")
        #expect(launch.arguments == ["--first", "literal argument"])
        #expect(launch.providerEndpoint == manual.endpoint)
        #expect(launch.model == manual.model)
        #expect(launch.apiKey == "manual-fixture-key")
        #expect(settings.agentProvider(for: AgentConfiguration.customAgentID) == manual)
        #expect(cli.loadCount == 0 && cli.modelLoadCount == 0)
        #expect(keys.readCount == 1)
    }

    @Test
    func subscriptionSkipsAPIConfigurationAndRejectsOtherAgents() throws {
        let settings = AppSettings(store: LaunchSettingsStore())
        settings.agentConfigurations["codex-acp"] = AgentConfiguration(name: "Codex", providerID: nil,
            authentication: .codexSubscription)
        let cli = LaunchConfigurationSource(snapshots: [snapshot(.codex, revision: "other")])
        let keys = LaunchCredentialResolver(key: "must-not-use-this-key")
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [cli], credentialResolver: keys)
        let launch = try resolve(resolver, agentID: "codex-acp")
        #expect(launch.authentication == .codexSubscription)
        #expect(launch.providerEndpoint.isEmpty && launch.apiKey.isEmpty && launch.model.isEmpty)
        settings.agentConfigurations["claude-acp"] = AgentConfiguration(name: "Claude", providerID: nil,
            authentication: .codexSubscription)
        #expect(throws: AgentConversationError.missingProvider) { try resolve(resolver, agentID: "claude-acp") }
        #expect(cli.loadCount == 0 && cli.modelLoadCount == 0)
        #expect(keys.readCount == 0)
    }

    @Test
    func refreshRejectsOtherSourcesManualProfilesAndDeletedIdentities() {
        let settings = AppSettings(store: LaunchSettingsStore())
        let imported = settings.importAIConfiguration(snapshot(.codex, revision: "old"))
        let manual = AIProviderProfile(name: "Manual", endpoint: "https://manual.example.test/v1",
            model: "manual-model", apiProtocol: .responses)
        settings.commitMessageAI.providers.append(manual)
        let before = settings.commitMessageAI
        #expect(settings.refreshImportedAIProvider(imported.id, from: snapshot(.claude, revision: "other")) == nil)
        #expect(settings.refreshImportedAIProvider(manual.id, from: snapshot(.codex, revision: "other")) == nil)
        #expect(settings.refreshImportedAIProvider(UUID(), from: snapshot(.codex, revision: "other")) == nil)
        #expect(settings.commitMessageAI == before)
    }

    private func resolve(_ resolver: AgentLaunchConfigurationResolver, agentID: String) throws -> AgentLaunchConfiguration {
        try resolver.resolve(agentID: agentID, workspaceURL: URL(fileURLWithPath: "/fixture/workspace"),
            dataDirectory: URL(fileURLWithPath: "/fixture/agent-data"))
    }

    private func agentID(_ source: AIConfigurationSourceKind) -> String {
        source == .codex ? "codex-acp" : "claude-acp"
    }

    private func snapshot(_ source: AIConfigurationSourceKind, revision: String, key: String? = nil) -> AIConfigurationSnapshot {
        AIConfigurationSnapshot(source: source, providerName: revision, endpoint: "https://\(revision).example.test/v1",
            model: "\(revision)-model", apiProtocol: source == .codex ? .responses : .anthropicMessages,
            authentication: revision == "old" ? .bearer : .apiKey, reasoningEffort: .high,
            requiresAPIKey: revision != "old", apiKey: key ?? "\(revision)-fixture-key")
    }
}

private final class LaunchConfigurationSource: AIConfigurationSource, @unchecked Sendable {
    let snapshots: [AIConfigurationSnapshot]
    let model: AIConfigurationModel?
    private(set) var loadCount = 0
    private(set) var modelLoadCount = 0

    init(snapshots: [AIConfigurationSnapshot], model: AIConfigurationModel? = nil) {
        self.snapshots = snapshots
        self.model = model
    }

    func load() -> AIConfigurationSnapshot? {
        loadCount += 1
        guard !snapshots.isEmpty else { return nil }
        return snapshots[min(loadCount - 1, snapshots.count - 1)]
    }

    func loadModel() -> AIConfigurationModel? {
        modelLoadCount += 1
        return model
    }
}

private final class LaunchCredentialResolver: AIProviderCredentialResolver, @unchecked Sendable {
    let key: String
    private(set) var readCount = 0
    init(key: String) { self.key = key }
    func readAPIKey(for provider: AIProviderProfile) -> String? {
        readCount += 1
        return key
    }
}

private final class LaunchSettingsStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
