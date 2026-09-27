import AppKit
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("Agent provider configuration")
struct AgentProviderConfigurationTests {
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
            try feature.save(provider, key: key)
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
        try feature.save(provider, key: key)
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
        #expect(throws: ProviderStorageError.self) { try feature.save(provider, key: key) }
        #expect(settings.commitMessageAI == before)
        keys.fail = false
        try feature.save(provider, key: key)
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
        try feature.save(first, key: key)
        let count = settings.commitMessageAI.providers.count
        var edit = try feature.draft(source: .codex, provider: first)
        edit.name = "Renamed"
        let (updated, newKey) = try feature.validate(edit)
        try feature.save(updated, key: newKey)
        #expect(updated.id == first.id)
        #expect(updated.apiKeyIdentifier == first.apiKeyIdentifier)
        #expect(settings.commitMessageAI.providers.count == count)
        #expect(settings.commitMessageAI.providers.last?.name == "Renamed")
        try feature.remove(updated)
        #expect(throws: AgentProviderConfigurationError.self) { try feature.validate(edit) }
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
