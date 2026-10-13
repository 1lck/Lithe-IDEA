import AppKit
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Agent provider configuration")
struct AgentProviderConfigurationTests {
    @Test func subscriptionBindingRoundTripsWithoutBecomingAnAPIProvider() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let before = settings.commitMessageAI
        let configuration = AgentConfiguration(name: "Codex", providerID: nil, authentication: .codexSubscription)
        settings.agentConfigurations["codex-acp"] = configuration
        #expect(settings.agentProvider(for: "codex-acp") == nil)
        #expect(settings.commitMessageAI == before)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
        #expect(decoded.isConfigured)
        let legacy = try JSONDecoder().decode(AgentConfiguration.self, from: Data(#"{"name":"Codex","providerID":null}"#.utf8))
        #expect(legacy.authentication == .apiKey)
        #expect(!legacy.isConfigured)
        settings.setAgentProvider(nil, for: "codex-acp", name: "Codex")
        #expect(settings.agentConfigurations["codex-acp"]?.authentication == .apiKey)
        #expect(settings.agentConfigurations["codex-acp"]?.isConfigured == false)
    }

    @Test func configurationInputKeepsLiteralSyntax() {
        let editor = MacConfigurationTextView()
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        let toml = "model = \"fixture-model\"\n"
        editor.insertText(toml, replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.string == toml)
        let json = #"{"OPENAI_API_KEY":"fixture-secret"}"#
        editor.insertText(json, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(editor.string == json)
    }

    @Test @MainActor
    func newCodexDraftUsesOfficialModelAndEditingKeepsSavedModel() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())

        let newDraft = try feature.draft(source: .codex)
        #expect(newDraft.configuration.contains("model = \"gpt-6.1-sol\""))

        let saved = AIProviderProfile(name: "Saved", endpoint: "https://example.test/v1", model: "saved-model",
            apiProtocol: .responses, apiKeyIdentifier: "saved-key")
        let edit = try feature.draft(source: .codex, provider: saved)
        #expect(edit.configuration.contains("model = \"saved-model\""))
        #expect(!edit.configuration.contains("gpt-6.1-sol"))
    }

    @Test
    func addingGenericProviderRequiresAnExplicitModelAfterSwitchingToClaude() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let providerID = settings.addAIProvider()
        settings.updateAIProvider(providerID) {
            $0.endpoint = "https://example.test/v1"
            $0.apiProtocol = .anthropicMessages
        }
        settings.setAgentProvider(providerID, for: "claude-acp", name: "Claude")

        let provider = try #require(settings.agentProvider(for: "claude-acp"))
        #expect(provider.model.isEmpty)
        #expect(!provider.isValid)
        let feature = AgentProviderConfiguration(settings: settings, secureStore: ProviderSecureStore(),
            parser: ProviderParser())
        let draft = try feature.draft(source: .claude, provider: provider)
        let json = try #require(JSONSerialization.jsonObject(with: Data(draft.configuration.utf8)) as? [String: Any])
        let environment = try #require(json["env"] as? [String: String])
        #expect(environment["ANTHROPIC_MODEL"] == "")
    }

    @Test(arguments: ["fixture-custom-model", "gpt-6.1-sol"])
    func switchingGenericProviderProtocolKeepsManuallyEnteredModel(model: String) throws {
        var settings = CommitMessageAISettings.default
        let provider = settings.addProvider()
        settings.updateActiveProvider { $0.model = model }
        settings.updateActiveProvider { $0.apiProtocol = .anthropicMessages }
        let selected = try #require(settings.activeProvider)
        #expect(selected.model == model)
        #expect(settings.activeProviderID == provider.id)

        let feature = AgentProviderConfiguration(settings: AppSettings(store: ProviderSettingsStore()),
            secureStore: ProviderSecureStore(), parser: ProviderParser())
        let draft = try feature.draft(source: .claude, provider: selected)
        let json = try #require(JSONSerialization.jsonObject(with: Data(draft.configuration.utf8)) as? [String: Any])
        let environment = try #require(json["env"] as? [String: String])
        #expect(environment["ANTHROPIC_MODEL"] == model)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_AGENT_PROVIDER_INTEGRATION"] == "1"))
    func nativeParserUsesSharedFixtureAndRoundTripsEditorTemplates() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/agent/provider-configuration-v1.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        let parser = MacAgentProviderConfigurationParser(core: RustCoreBridge())
        #expect(throws: AgentProviderConfigurationError.invalidConfigurationQuotes) {
            try parser.parse(source: .codex, configuration: "model = “fixture-model”",
                authentication: #"{"OPENAI_API_KEY":"fixture-secret"}"#)
        }
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: parser)
        for value in cases {
            let sourceName = try #require(value["source"] as? String)
            let source = try #require(AIConfigurationSourceKind(rawValue: sourceName))
            let configuration = try #require(value["configuration"] as? String)
            let expected = try #require(value["expected"] as? [String: String])
            var draft = AgentProviderDraft(source: source, name: "Fixture", configuration: configuration,
                authentication: #"{"OPENAI_API_KEY":"fixture-secret"}"#)
            let (provider, key) = try feature.validate(draft)
            #expect(provider.endpoint == expected["endpoint"])
            #expect(provider.model == expected["model"])
            #expect(provider.apiProtocol.rawValue == expected["apiProtocol"])
            #expect(key == "fixture-secret")
            try feature.save(provider, key: key, replacing: nil)
            // Editing reconstructs only the fields we promise to retain, including TOML string escaping.
            draft = try feature.draft(source: source, provider: provider)
            let (roundTrip, _) = try feature.validate(draft)
            #expect(roundTrip == provider)
            if source == .codex {
                draft.authentication = #"{"OPENAI_API_KEY":123}"#
                #expect(throws: AgentProviderConfigurationError.self) { try feature.validate(draft) }
            }
        }
        #expect(throws: AgentProviderConfigurationError.self) {
            try parser.parse(source: .claude, configuration: #"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"}}"#, authentication: "")
        }
    }
    @Test func unreadableCredentialStorePreservesItsContents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("provider-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for text in ["malformed fixture", #"{"version":99,"values":{"fixture":"opaque"}}"#] {
            let original = Data(text.utf8)
            try original.write(to: url)
            let store = MacLocalSecretStore(fileURL: url)
            #expect(throws: (any Error).self) { try store.write("fixture-secret", key: "provider") }
            #expect(throws: (any Error).self) { try store.delete(key: "provider") }
            #expect(try Data(contentsOf: url) == original)
        }
    }
    @Test func savesKeySeparatelyAndPreservesCommitProvider() throws {
        let store = ProviderSettingsStore()
        let settings = AppSettings(store: store)
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())
        settings.commitMessageAI.activeProviderID = nil
        var draft = try feature.draft(source: .codex)
        draft.name = " My provider "
        let (provider, key) = try feature.validate(draft)
        try feature.save(provider, key: key, replacing: nil)
        #expect(settings.commitMessageAI.activeProviderID == nil)
        #expect(settings.commitMessageAI.providers.last?.name == "My provider")
        #expect(keys.read(key: provider.apiKeyIdentifier) == "fixture-secret")
        let persisted = String(decoding: try JSONEncoder().encode(settings.commitMessageAI), as: UTF8.self)
        #expect(!persisted.contains("fixture-secret"))
        let restored = AppSettings(store: store)
        #expect(restored.commitMessageAI.providers.contains { $0.id == provider.id })
        #expect(restored.commitMessageAI.activeProviderID == nil)
    }

    @Test func draftCancellationHasNoPersistenceEffects() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())
        let before = settings.commitMessageAI
        let draft = try feature.draft(source: .claude)
        #expect(draft.providerID == nil)
        #expect(settings.commitMessageAI == before)
        #expect(keys.values.isEmpty)
    }

    @Test func failedStorageDoesNotPublishOrDeleteProfile() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())
        var draft = try feature.draft(source: .codex)
        draft.name = "Fixture"
        let (provider, key) = try feature.validate(draft)
        let before = settings.commitMessageAI
        keys.fail = true
        #expect(throws: ProviderStorageError.self) { try feature.save(provider, key: key, replacing: nil) }
        #expect(settings.commitMessageAI == before)
        keys.fail = false
        try feature.save(provider, key: key, replacing: nil)
        settings.setAgentProvider(provider.id, for: "codex-acp", name: "Codex")
        keys.fail = true
        #expect(throws: ProviderStorageError.self) { try feature.remove(provider) }
        #expect(settings.agentProvider(for: "codex-acp")?.id == provider.id)
        keys.fail = false
        try feature.remove(provider)
        #expect(settings.agentProvider(for: "codex-acp") == nil)
        #expect(keys.read(key: provider.apiKeyIdentifier) == nil)
    }

    @Test func editingKeepsProviderAndCredentialIdentity() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())
        var draft = try feature.draft(source: .codex)
        draft.name = "First"
        let (first, key) = try feature.validate(draft)
        try feature.save(first, key: key, replacing: nil)
        let count = settings.commitMessageAI.providers.count
        var edit = try feature.draft(source: .codex, provider: first)
        edit.name = "Renamed"
        let (updated, newKey) = try feature.validate(edit)
        try feature.save(updated, key: newKey, replacing: first)
        #expect(updated.id == first.id)
        #expect(updated.apiKeyIdentifier == first.apiKeyIdentifier)
        #expect(settings.commitMessageAI.providers.count == count)
        #expect(settings.commitMessageAI.providers.last?.name == "Renamed")
        try feature.remove(updated)
        #expect(throws: AgentProviderConfigurationError.self) { try feature.validate(edit) }
    }

    @Test(arguments: [false, true])
    func suspendedSaveRejectsDeletedOrChangedProvider(otherWindowEdits: Bool) throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser())
        var draft = try feature.draft(source: .codex)
        draft.name = "Original"
        let (original, key) = try feature.validate(draft)
        try feature.save(original, key: key, replacing: nil)
        settings.setAgentProvider(original.id, for: "codex-acp", name: "Codex")

        var edit = try feature.draft(source: .codex, provider: original)
        edit.name = "Late edit"
        let (pending, pendingKey) = try feature.validate(edit)
        // The first window has validated and is awaiting connection closure. Apply the
        // second window's mutation before resuming its save, without scheduler timing.
        let otherWindow = AgentProviderConfiguration(settings: settings, secureStore: keys,
            parser: ProviderParser(key: "replacement-secret"))
        if otherWindowEdits {
            var replacement = try otherWindow.draft(source: .codex, provider: original)
            replacement.name = "Other window"
            let (provider, replacementKey) = try otherWindow.validate(replacement)
            try otherWindow.save(provider, key: replacementKey, replacing: original)
        } else {
            try otherWindow.remove(original)
        }
        let expectedProfiles = settings.commitMessageAI
        let expectedKeys = keys.values
        let expectedSelection = settings.agentProvider(for: "codex-acp")

        #expect(throws: AgentProviderConfigurationError.invalidConfiguration) {
            try feature.save(pending, key: pendingKey, replacing: original)
        }
        #expect(settings.commitMessageAI == expectedProfiles)
        #expect(keys.values == expectedKeys, "A stale save must not restore or overwrite credentials")
        #expect(settings.agentProvider(for: "codex-acp") == expectedSelection)
    }

    @Test func rejectsProtocolMismatchAndCredentialBearingURLs() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let protocols: [CommitMessageAPIProtocol] = [.chatCompletions, .anthropicMessages]
        for apiProtocol in protocols {
            let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser(apiProtocol: apiProtocol))
            var draft = try feature.draft(source: .codex)
            draft.name = "Fixture"
            #expect(throws: AgentProviderConfigurationError.self) { try feature.validate(draft) }
        }
        for endpoint in ["https://user:password@example.test", "https://example.test?key=secret", "file:///example", "https://example.test#fragment"] {
            let feature = AgentProviderConfiguration(settings: settings, secureStore: keys, parser: ProviderParser(endpoint: endpoint))
            var draft = try feature.draft(source: .codex)
            draft.name = "Fixture"
            #expect(throws: AgentProviderConfigurationError.self) { try feature.validate(draft) }
        }
        #expect(keys.values.isEmpty)
    }

    @Test func requiresExplicitHTTPConsentAndNonemptyKey() throws {
        let settings = AppSettings(store: ProviderSettingsStore())
        let keys = ProviderSecureStore()
        let http = AgentProviderConfiguration(settings: settings, secureStore: keys,
            parser: ProviderParser(endpoint: "http://example.test/v1"))
        var draft = try http.draft(source: .codex)
        draft.name = "Fixture"
        #expect(throws: AgentProviderConfigurationError.self) { try http.validate(draft) }
        draft.allowsInsecureHTTP = true
        #expect(try http.validate(draft).0.allowsInsecureHTTP)
        let missingKey = AgentProviderConfiguration(settings: settings, secureStore: keys,
            parser: ProviderParser(key: " \n"))
        #expect(throws: AgentProviderConfigurationError.self) { try missingKey.validate(draft) }
        #expect(keys.values.isEmpty)
    }
}

private struct ProviderParser: AgentProviderConfigurationParsing {
    var endpoint = "https://example.test/v1"
    var apiProtocol: CommitMessageAPIProtocol = .responses
    var key: String? = "fixture-secret"
    func parse(source: AIConfigurationSourceKind, configuration: String, authentication: String) throws -> AIConfigurationSnapshot {
        AIConfigurationSnapshot(source: source, providerName: "fixture", endpoint: endpoint, model: "fixture-model",
            apiProtocol: apiProtocol, reasoningEffort: nil, requiresAPIKey: true, apiKey: key)
    }
}
private enum ProviderStorageError: Error { case failed }
private final class ProviderSecureStore: SecureStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var fail = false
    func read(key: String) -> String? { values[key] }
    func write(_ value: String, key: String) throws {
        if fail { throw ProviderStorageError.failed }
        values[key] = value
    }
    func delete(key: String) throws {
        if fail { throw ProviderStorageError.failed }
        values[key] = nil
    }
}
private final class ProviderSettingsStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
