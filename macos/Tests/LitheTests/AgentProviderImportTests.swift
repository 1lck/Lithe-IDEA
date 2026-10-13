import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Agent provider imports")
struct AgentProviderImportTests {
    @Test(arguments: [AIConfigurationSourceKind.codex, .claude])
    func importingBothSourcesKeepsBindingsAndReimportsIsolated(firstSource: AIConfigurationSourceKind) throws {
        let store = ProviderImportSettingsStore()
        let settings = AppSettings(store: store)
        let secondSource: AIConfigurationSourceKind = firstSource == .codex ? .claude : .codex
        let first = settings.importAIConfiguration(snapshot(firstSource))
        settings.setAgentProvider(first.id, for: agentID(firstSource), name: firstSource.title)
        let second = settings.importAIConfiguration(snapshot(secondSource))
        settings.setAgentProvider(second.id, for: agentID(secondSource), name: secondSource.title)

        #expect(first.id != second.id)
        #expect(settings.agentProvider(for: agentID(firstSource)) == first)
        #expect(settings.agentProvider(for: agentID(secondSource)) == second)

        let refreshed = settings.importAIConfiguration(snapshot(firstSource, model: "refreshed-fixture-model"))
        #expect(refreshed.id == first.id)
        #expect(settings.agentProvider(for: agentID(secondSource)) == second)
        let reloaded = AppSettings(store: store)
        #expect(reloaded.agentProvider(for: agentID(firstSource)) == refreshed)
        #expect(reloaded.agentProvider(for: agentID(secondSource)) == second)
        let persisted = try #require(store.data(forKey: "settings.commitMessageAI"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("fixture-secret"))
    }

    @Test
    func importingOnlyCodexLeavesClaudeUnconfigured() {
        let settings = AppSettings(store: ProviderImportSettingsStore())
        let provider = settings.importAIConfiguration(snapshot(.codex))
        settings.setAgentProvider(provider.id, for: "codex-acp", name: "Codex")

        #expect(provider.apiKeyIdentifier == "lithe.codex.imported.apiKey")
        #expect(settings.agentProvider(for: "claude-acp") == nil)
        #expect(settings.agentConfigurations["claude-acp"] == nil)
    }

    @Test(arguments: [AIConfigurationSourceKind.codex, .claude])
    func reloadingRepairsLegacyCollisionWithoutReassigningOtherProviders(source: AIConfigurationSourceKind) throws {
        let store = ProviderImportSettingsStore()
        let legacy = AIProviderProfile(name: source.title, endpoint: "https://import.example.test/v1",
            model: "fixture-model", apiProtocol: source == .codex ? .responses : .anthropicMessages,
            apiKeyIdentifier: "lithe.(snapshot.source.rawValue).imported.apiKey", credentialSource: source.credentialSource)
        var providers = CommitMessageAISettings.default
        providers.providers = [legacy]
        providers.activeProviderID = legacy.id
        let bindings = [
            "codex-acp": AgentConfiguration(name: "Codex", providerID: legacy.id),
            "claude-acp": AgentConfiguration(name: "Claude", providerID: legacy.id),
            "custom": AgentConfiguration(name: "Fixture custom", providerID: legacy.id)
        ]
        store.set(try JSONEncoder().encode(providers), forKey: "settings.commitMessageAI")
        store.set(try JSONEncoder().encode(bindings), forKey: "settings.agentConfigurations")

        let settings = AppSettings(store: store)
        let otherSource: AIConfigurationSourceKind = source == .codex ? .claude : .codex
        var repaired = legacy
        repaired.apiKeyIdentifier = "lithe.\(source.rawValue).imported.apiKey"
        #expect(settings.agentProvider(for: agentID(source)) == repaired)
        #expect(settings.agentProvider(for: agentID(otherSource)) == nil)
        #expect(settings.agentConfigurations[agentID(otherSource)]?.isConfigured == false)
        #expect(settings.agentProvider(for: "custom") == repaired)
        #expect(settings.activeCommitMessageProvider == repaired)
        #expect(settings.commitMessageAI.providers.count == 1)
        let reloaded = AppSettings(store: store)
        #expect(reloaded.commitMessageAI == settings.commitMessageAI)
        #expect(reloaded.agentConfigurations == settings.agentConfigurations)
    }

    @Test
    func correctedIdentifierStillRepairsAnImportedSourceMismatch() throws {
        // Refreshing a commit provider can already have corrected the identifier,
        // while leaving both agents linked to the overwritten Codex profile.
        let store = ProviderImportSettingsStore()
        let imported = AIProviderProfile(name: "Codex", endpoint: "https://codex.example.test/v1",
            model: "fixture-model", apiProtocol: .responses,
            apiKeyIdentifier: "lithe.codex.imported.apiKey", credentialSource: .codex)
        var providers = CommitMessageAISettings.default
        providers.providers = [imported]
        providers.activeProviderID = imported.id
        let bindings = ["claude-acp": AgentConfiguration(name: "Claude", providerID: imported.id),
                        "codex-acp": AgentConfiguration(name: "Codex", providerID: nil, authentication: .codexSubscription)]
        store.set(try JSONEncoder().encode(providers), forKey: "settings.commitMessageAI")
        store.set(try JSONEncoder().encode(bindings), forKey: "settings.agentConfigurations")

        let settings = AppSettings(store: store)
        #expect(settings.agentProvider(for: "claude-acp") == nil)
        #expect(settings.agentConfigurations["codex-acp"] == bindings["codex-acp"])
        #expect(settings.activeCommitMessageProvider == imported)
    }

    @Test
    func overwrittenProfileReferencesBecomeUnconfigured() throws {
        let store = ProviderImportSettingsStore()
        let surviving = AIProviderProfile(name: "Codex", endpoint: "https://codex.example.test/v1",
            model: "fixture-model", apiProtocol: .responses,
            apiKeyIdentifier: "lithe.(snapshot.source.rawValue).imported.apiKey", credentialSource: .codex)
        var providers = CommitMessageAISettings.default
        providers.providers = [surviving]
        providers.activeProviderID = surviving.id
        // A refresh had separated the old Codex identifier before the collision
        // removed that profile and reused Claude's ID for the new Codex import.
        let bindings = ["codex-acp": AgentConfiguration(name: "Codex", providerID: UUID()),
                        "claude-acp": AgentConfiguration(name: "Claude", providerID: surviving.id)]
        store.set(try JSONEncoder().encode(providers), forKey: "settings.commitMessageAI")
        store.set(try JSONEncoder().encode(bindings), forKey: "settings.agentConfigurations")

        let settings = AppSettings(store: store)
        #expect(settings.agentConfigurations.values.allSatisfy { !$0.isConfigured })
        #expect(settings.activeCommitMessageProvider?.id == surviving.id)
        #expect(AppSettings(store: store).agentConfigurations == settings.agentConfigurations)
    }

    @Test
    func reloadingPreservesManualProvidersAndTheirBindings() throws {
        let store = ProviderImportSettingsStore()
        let settings = AppSettings(store: store)
        let manual = AIProviderProfile(name: "Manual", endpoint: "https://manual.example.test/v1",
            model: "fixture-model", apiProtocol: .responses, credentialSource: .local)
        settings.commitMessageAI.providers = [manual]
        settings.commitMessageAI.activeProviderID = manual.id
        settings.setAgentProvider(manual.id, for: "codex-acp", name: "Codex")
        settings.setAgentProvider(manual.id, for: "custom", name: "Fixture custom")

        let reloaded = AppSettings(store: store)
        #expect(reloaded.commitMessageAI == settings.commitMessageAI)
        #expect(reloaded.agentConfigurations == settings.agentConfigurations)
    }

    private func agentID(_ source: AIConfigurationSourceKind) -> String {
        source == .codex ? "codex-acp" : "claude-acp"
    }

    private func snapshot(_ source: AIConfigurationSourceKind, model: String? = nil) -> AIConfigurationSnapshot {
        AIConfigurationSnapshot(source: source, providerName: "Fixture", endpoint: "https://import.example.test/v1",
            model: model ?? "\(source.rawValue)-fixture-model", apiProtocol: source == .codex ? .responses : .anthropicMessages,
            reasoningEffort: nil, requiresAPIKey: true, apiKey: "fixture-secret")
    }
}

private final class ProviderImportSettingsStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
