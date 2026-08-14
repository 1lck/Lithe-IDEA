import AppKit
import Foundation
import LitheAIAssistanceModule
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Commit message generation")
struct CommitMessageTests {
    @Test
    func parsesCodexResponsesConfigurationAndAuthKey() throws {
        let config = """
        model_provider = "custom"
        model = "gpt-5.6-luna"
        model_reasoning_effort = "max"

        [model_providers.custom]
        wire_api = "responses"
        requires_openai_auth = true
        base_url = "https://example.test/codex/v1"
        """
        let auth = Data(#"{"OPENAI_API_KEY":"test-secret"}"#.utf8)

        let snapshot = MacCodexConfigurationParser.parse(config: config, authData: auth)

        #expect(snapshot?.providerName == "custom")
        #expect(snapshot?.endpoint == "https://example.test/codex/v1")
        #expect(snapshot?.model == "gpt-5.6-luna")
        #expect(snapshot?.apiProtocol == .responses)
        #expect(snapshot?.reasoningEffort == .max)
        #expect(snapshot?.requiresAPIKey == true)
        #expect(snapshot?.apiKey == "test-secret")
    }

    @Test
    func parsesClaudeConfigurationFromSettingsAndEnvironment() throws {
        let settings = Data("""
        {
            "model": "claude-sonnet-custom",
            "env": {
                "ANTHROPIC_BASE_URL": "https://proxy.example.test/v1",
                "ANTHROPIC_API_KEY": "claude-secret"
            }
        }
        """.utf8)

        let snapshot = MacClaudeConfigurationParser.parse(
            settingsData: settings,
            credentialsData: nil,
            rootConfigData: nil,
            environment: [:]
        )

        #expect(snapshot?.source == .claude)
        #expect(snapshot?.endpoint == "https://proxy.example.test/v1")
        #expect(snapshot?.model == "claude-sonnet-custom")
        #expect(snapshot?.apiProtocol == .anthropicMessages)
        #expect(snapshot?.apiKey == "claude-secret")
        #expect(snapshot?.authentication == .apiKey)
        #expect(snapshot?.requiresAPIKey == true)
    }

    @Test
    func parsesClaudeAuthTokenAndResolvesModelAlias() throws {
        let settings = Data("""
        {
            "model": "opus",
            "env": {
                "ANTHROPIC_AUTH_TOKEN": "auth-token",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-custom"
            }
        }
        """.utf8)

        let snapshot = MacClaudeConfigurationParser.parse(
            settingsData: settings,
            credentialsData: nil,
            rootConfigData: nil,
            environment: [:]
        )

        #expect(snapshot?.model == "claude-opus-custom")
        #expect(snapshot?.apiKey == "auth-token")
        #expect(snapshot?.authentication == .bearer)
    }

    @Test
    func anthropicGenerationUsesNativeMessagesRequestAndHeaders() async throws {
        let profile = AIProviderProfile(
            name: "Claude",
            endpoint: "https://api.anthropic.com",
            model: "claude-sonnet-custom",
            apiProtocol: .anthropicMessages,
            apiKeyIdentifier: "claude-key",
            requiresAPIKey: true,
            credentialSource: .local
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":[{"type":"text","text":"feat: update checker"}]}"#.utf8)
            )
        )
        let credentialResolver = InMemoryAIProviderCredentialResolver(
            values: ["claude-key": "claude-secret"]
        )
        let service = CommitMessageGenerationService(
            transport: transport,
            credentialResolver: credentialResolver
        )

        let input = CommitMessageInput(
            path: "Sources/UpdateChecker.swift",
            changeKind: .modified,
            diff: "@@ -1,1 +1,2 @@\n-old\n+new"
        )
        let message = try await service.generate(input: input, settings: settings)

        #expect(message == "feat: update checker")
        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request?.headers["x-api-key"] == "claude-secret")
        #expect(request?.headers["Authorization"] == nil)
        #expect(request?.headers["anthropic-version"] == "2023-06-01")

        let body = try #require(request?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-custom")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["system"] as? String != nil)
        #expect(json["messages"] as? [[String: Any]] != nil)
    }

    @Test
    func httpProviderRequiresExplicitOptIn() async throws {
        let profile = AIProviderProfile(
            name: "HTTP proxy",
            endpoint: "http://127.0.0.1:8888",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            apiKeyIdentifier: "http-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"feat: update checker"}}]}"#.utf8))
        )
        let service = CommitMessageGenerationService(
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: ["http-key": "secret"])
        )

        do {
            _ = try await service.generate(input: testCommitMessageInput, settings: settings)
            Issue.record("HTTP generation should require explicit opt-in")
        } catch let error as CommitMessageGenerationError {
            guard case .insecureEndpoint = error else {
                Issue.record("HTTP generation returned the wrong error")
                return
            }
        }
        #expect(await transport.lastRequest == nil)
    }

    @Test
    func httpProviderCarriesExplicitOptInToTransport() async throws {
        let profile = AIProviderProfile(
            name: "HTTP proxy",
            endpoint: "http://127.0.0.1:8888",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            allowsInsecureHTTP: true,
            apiKeyIdentifier: "http-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"feat: update checker"}}]}"#.utf8))
        )
        let service = CommitMessageGenerationService(
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(values: ["http-key": "secret"])
        )

        #expect(try await service.generate(input: testCommitMessageInput, settings: settings) == "feat: update checker")
        #expect(await transport.lastRequest?.allowsInsecureHTTP == true)
    }

    @Test
    func responsesGenerationUsesConfiguredEndpointModelReasoningAndKey() async throws {
        let profile = AIProviderProfile(
            name: "Test Codex",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            apiKeyIdentifier: "test-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id
        settings.reasoningEffort = .low

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"output_text":"feat: update checker"}"#.utf8)
            )
        )
        let credentialResolver = InMemoryAIProviderCredentialResolver(
            values: ["test-key": "test-secret"]
        )
        let service = CommitMessageGenerationService(
            transport: transport,
            credentialResolver: credentialResolver
        )

        let input = CommitMessageInput(
            path: "Sources/UpdateChecker.swift",
            changeKind: .modified,
            diff: "@@ -1,1 +1,2 @@\n-old\n+new"
        )
        let message = try await service.generate(input: input, settings: settings)

        #expect(message == "feat: update checker")
        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://example.test/codex/v1/responses")
        #expect(request?.headers["Authorization"] == "Bearer test-secret")

        let body = try #require(request?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "fast-model")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
        #expect(json["store"] as? Bool == false)
    }

    @Test
    func generationSendsTheCompleteStagedFileSetWithBoundaries() async throws {
        let profile = AIProviderProfile(
            name: "Test provider",
            endpoint: "https://example.test/api",
            model: "fast-model",
            apiProtocol: .chatCompletions,
            apiKeyIdentifier: "test-key",
            requiresAPIKey: true
        )
        var settings = CommitMessageAISettings.default
        settings.providers = [profile]
        settings.activeProviderID = profile.id

        let transport = MockAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                body: Data(#"{"choices":[{"message":{"content":"docs: update project documentation"}}]}"#.utf8)
            )
        )
        let service = CommitMessageGenerationService(
            transport: transport,
            credentialResolver: InMemoryAIProviderCredentialResolver(
                values: ["test-key": "test-secret"]
            )
        )
        let input = CommitMessageInput(files: [
            CommitMessageFileInput(
                path: "README.md",
                changeKind: .modified,
                diff: "@@ -1 +1 @@\n-old docs\n+new docs"
            ),
            CommitMessageFileInput(
                path: "README.zh-CN.md",
                changeKind: .modified,
                diff: "@@ -1 +1 @@\n-旧文档\n+新文档"
            )
        ])

        _ = try await service.generate(input: input, settings: settings)

        let body = try #require(await transport.lastRequest?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userPrompt = try #require(messages[1]["content"] as? String)
        #expect(userPrompt.contains("path: README.md"))
        #expect(userPrompt.contains("path: README.zh-CN.md"))
        #expect(userPrompt.components(separatedBy: "--- BEGIN STAGED FILE ---").count == 3)
        #expect(userPrompt.components(separatedBy: "--- END STAGED FILE ---").count == 3)

        let systemPrompt = try #require(messages[0]["content"] as? String)
        #expect(systemPrompt.contains("complete set of staged changes"))
        #expect(systemPrompt.contains("Do not infer a feature from a filename alone"))
    }
}

private let testCommitMessageInput = CommitMessageInput(
    path: "Sources/UpdateChecker.swift",
    changeKind: .modified,
    diff: "@@ -1,1 +1,2 @@\n-old\n+new"
)

@Suite("Commit message settings")
@MainActor
struct CommitMessageSettingsTests {
    @Test
    func themeSettingsPersistAndDefaultToDarkLithe() {
        let store = InMemoryKeyValueStore()
        let initialSettings = AppSettings(store: store)
        #expect(initialSettings.colorTheme == .lithe)
        #expect(initialSettings.themePreference == .dark)
        #expect(AppThemeRuntime.shared.activeTheme == .lithe)

        initialSettings.colorTheme = .linear
        initialSettings.themePreference = .light
        #expect(AppThemeRuntime.shared.activeTheme == .linear)
        let reloadedSettings = AppSettings(store: store)
        #expect(reloadedSettings.colorTheme == .linear)
        #expect(reloadedSettings.themePreference == .light)

        reloadedSettings.restoreDefaults()
        #expect(reloadedSettings.colorTheme == .lithe)
        #expect(reloadedSettings.themePreference == .dark)
    }

    @Test
    func bundledThemeTokensMatchTheirDefinitions() {
        let cases: [(AppColorTheme, Bool, LitheTheme.ResolvedColorToken, UInt32)] = [
            (.codex, true, .editor, 0x111111),
            (.codex, true, .primaryText, 0xfcfcfc),
            (.codex, true, .accent, 0x0169cc),
            (.codex, true, .success, 0x00a240),
            (.codex, true, .error, 0xe02e2a),
            (.codex, true, .skill, 0xb06dff),
            (.codex, false, .editor, 0xffffff),
            (.codex, false, .primaryText, 0x0d0d0d),
            (.codex, false, .accent, 0x0169cc),
            (.codex, false, .success, 0x00a240),
            (.codex, false, .error, 0xe02e2a),
            (.codex, false, .skill, 0x751ed9),
            (.linear, true, .editor, 0x0f0f11),
            (.linear, true, .primaryText, 0xe3e4e6),
            (.linear, true, .accent, 0x606acc),
            (.linear, true, .success, 0x69c967),
            (.linear, true, .error, 0xff7e78),
            (.linear, true, .skill, 0xc2a1ff),
            (.linear, false, .editor, 0xfcfcfd),
            (.linear, false, .primaryText, 0x1b1b1b),
            (.linear, false, .accent, 0x5e6ad2),
            (.linear, false, .success, 0x52a450),
            (.linear, false, .error, 0xc94446),
            (.linear, false, .skill, 0x8160d8)
        ]

        for (theme, isDark, token, expected) in cases {
            let color = LitheTheme.nsColor(token, theme: theme, isDark: isDark)
            #expect(rgbHex(color) == expected)
        }
    }

    private func rgbHex(_ color: NSColor) -> UInt32? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    @Test
    func projectOpenBehaviorPersistsAndDefaultsToAsk() {
        let store = InMemoryKeyValueStore()
        let initialSettings = AppSettings(store: store)
        #expect(initialSettings.projectOpenBehavior == .ask)

        initialSettings.projectOpenBehavior = .thisWindow
        let reloadedSettings = AppSettings(store: store)
        #expect(reloadedSettings.projectOpenBehavior == .thisWindow)
    }

    @Test
    func javaLanguageServerJDKPersistsGloballyAndRestoresToUnconfigured() {
        let store = InMemoryKeyValueStore()
        let initialSettings = AppSettings(store: store)
        #expect(initialSettings.javaLanguageServerJDKPath.isEmpty)

        initialSettings.javaLanguageServerJDKPath = "/test/jdks/lsp-21"
        let reloadedSettings = AppSettings(store: store)
        #expect(reloadedSettings.javaLanguageServerJDKPath == "/test/jdks/lsp-21")

        reloadedSettings.restoreDefaults()
        #expect(AppSettings(store: store).javaLanguageServerJDKPath.isEmpty)
    }

    @Test
    func importingCodexStoresOnlyTheCodexSourceReferenceInSettings() throws {
        let store = InMemoryKeyValueStore()
        let settings = AppSettings(store: store)
        let snapshot = CodexConfigurationSnapshot(
            providerName: "custom",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            reasoningEffort: .max,
            requiresAPIKey: true,
            apiKey: "test-secret"
        )

        let existingProvider = AIProviderProfile(
            name: "Codex",
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            allowsInsecureHTTP: true,
            apiKeyIdentifier: "lithe.codex.imported.apiKey",
            credentialSource: .codex
        )
        var initialSettings = settings.commitMessageAI
        initialSettings.providers = [existingProvider]
        initialSettings.activeProviderID = existingProvider.id
        settings.commitMessageAI = initialSettings

        let provider = settings.importCodexConfiguration(snapshot)

        #expect(settings.activeCommitMessageProvider?.id == provider.id)
        #expect(settings.activeCommitMessageProvider?.model == "fast-model")
        #expect(provider.credentialSource == .codex)
        #expect(provider.allowsInsecureHTTP == true)
        let persisted = try #require(store.data(forKey: "settings.commitMessageAI"))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        #expect(!persistedText.contains("test-secret"))
    }

    @Test
    func codexCredentialResolverReadsTheCurrentAuthConfiguration() {
        let snapshot = CodexConfigurationSnapshot(
            providerName: "custom",
            endpoint: "https://example.test/codex/v1",
            model: "fast-model",
            apiProtocol: .responses,
            reasoningEffort: .low,
            requiresAPIKey: true,
            apiKey: "codex-secret"
        )
        let source = FixedCodexConfigurationSource(snapshot: snapshot)
        let localStore = InMemorySecureStore(values: [
            "lithe.codex.imported.apiKey": "stale-local-secret"
        ])
        let resolver = MacAIProviderCredentialResolver(
            localStore: localStore,
            codexConfigurationSource: source
        )
        let provider = AIProviderProfile(
            name: "Codex",
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            apiKeyIdentifier: "lithe.codex.imported.apiKey",
            requiresAPIKey: true,
            credentialSource: .codex
        )

        #expect(resolver.readAPIKey(for: provider) == "codex-secret")
    }

    @Test
    func localSecretStorePersistsWithoutPlaintextAndUsesPrivateFilePermissions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-secrets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = MacLocalSecretStore(fileURL: fileURL)
        try store.write("test-secret", key: "provider-key")

        #expect(store.read(key: "provider-key") == "test-secret")
        let persisted = try Data(contentsOf: fileURL)
        #expect(!String(decoding: persisted, as: UTF8.self).contains("test-secret"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        let reloadedStore = MacLocalSecretStore(fileURL: fileURL)
        #expect(reloadedStore.read(key: "provider-key") == "test-secret")
        try reloadedStore.delete(key: "provider-key")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private actor MockAIHTTPTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    private(set) var lastRequest: AIHTTPRequest?

    init(response: AIHTTPResponse) {
        self.response = response
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        lastRequest = request
        return response
    }
}

private final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(key: String) -> String? {
        values[key]
    }

    func write(_ value: String, key: String) throws {
        values[key] = value
    }

    func delete(key: String) throws {
        values[key] = nil
    }
}

private final class InMemoryAIProviderCredentialResolver: AIProviderCredentialResolver, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func readAPIKey(for provider: AIProviderProfile) -> String? {
        values[provider.apiKeyIdentifier]
    }
}

private final class FixedCodexConfigurationSource: CodexConfigurationSource, @unchecked Sendable {
    let snapshot: CodexConfigurationSnapshot

    init(snapshot: CodexConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> CodexConfigurationSnapshot? {
        snapshot
    }
}

private final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
