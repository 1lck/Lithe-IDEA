import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import Testing
@testable import Lithe

/// Opt-in network coverage using an explicitly selected, already configured provider.
/// The caller owns an isolated CLAUDE_CONFIG_DIR and the temporary test root.
@MainActor
@Suite("Agent launch configuration real integration")
struct AgentLaunchConfigurationIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_AGENT_ROUTE_REAL"] == "1"))
    func cliSwitchAndHistoryResumeUseSelectedProvider() async throws {
        let environment = ProcessInfo.processInfo.environment
        let providerName = try #require(environment["LITHE_AGENT_ROUTE_TEST_PROVIDER"])
        let domain = try #require(environment["LITHE_AGENT_ROUTE_TEST_DEFAULTS"])
        let rootPath = try #require(environment["LITHE_AGENT_ROUTE_TEST_ROOT"])
        let isolatedCLI = try #require(environment["CLAUDE_CONFIG_DIR"])
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try #require(isolatedCLI.hasPrefix(root.path + "/"))
        let defaults = try #require(UserDefaults(suiteName: domain))
        // Decode without AppSettings so testing cannot repair or write user preferences.
        let stored = try JSONDecoder().decode(CommitMessageAISettings.self,
            from: try #require(defaults.data(forKey: "settings.commitMessageAI")))
        let matches = stored.providers.filter { $0.name == providerName && $0.credentialSource == .local }
        var provider = try #require(matches.count == 1 ? matches.first : nil)
        if let model = environment["LITHE_AGENT_ROUTE_TEST_MODEL"], !model.isEmpty { provider.model = model }
        try #require(provider.apiProtocol == .anthropicMessages)
        let secureStore = MacLocalSecretStore()
        let key = secureStore.read(key: provider.apiKeyIdentifier)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try #require(!key.isEmpty, "The selected provider must already have a saved credential")

        let home = root.appendingPathComponent("source-home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: workspace,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            for url in [home, workspace] {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record("Temporary Agent test files could not be removed") }
            }
        }
        let source = MacClaudeConfigurationSource(fileManager: RouteIntegrationFileManager(home: home))
        let store = RouteIntegrationSettingsStore()
        let settings = AppSettings(store: store)
        let credentials = MacAIProviderCredentialResolver(localStore: secureStore, configurationSources: [source])
        let resolver = AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: [source], credentialResolver: credentials)
        let dataDirectory = MacFileStorage().applicationSupportDirectory().appendingPathComponent("Lithe")
        // Check the manual branch with the same production credential adapter first.
        settings.commitMessageAI.providers = [provider]
        settings.commitMessageAI.activeProviderID = provider.id
        settings.setAgentProvider(provider.id, for: "claude-acp", name: "Claude")
        let manual = try resolver.resolve(agentID: "claude-acp", workspaceURL: workspace, dataDirectory: dataDirectory)
        try requireRoute(manual, provider: provider, key: key)

        try writeConfiguration(settingsURL, endpoint: "https://old.example.invalid", model: "old-fixture-model",
            key: "old-fixture-key")
        let imported = settings.importAIConfiguration(try #require(source.load()))
        settings.setAgentProvider(imported.id, for: "claude-acp", name: "Claude")
        settings.commitMessageAI.activeProviderID = provider.id
        let bindings = settings.agentConfigurations
        // External CLI switch happens after import, without a manual refresh action.
        try writeConfiguration(settingsURL, endpoint: provider.endpoint, model: provider.model, key: key)
        let launch = try resolver.resolve(agentID: "claude-acp", workspaceURL: workspace, dataDirectory: dataDirectory)
        try requireRoute(launch, provider: provider, key: key)
        #expect(settings.agentProvider(for: "claude-acp")?.id == imported.id)
        #expect(settings.agentConfigurations == bindings)
        #expect(settings.commitMessageAI.activeProviderID == provider.id)
        progress("CLI snapshot refreshed; starting selected provider with \(provider.model)")

        let model = AgentConnectionModel(transport: MacACPAgentTransport())
        do {
            try model.connect(configuration: launch)
            try await wait(on: model, seconds: 45, phase: "initial connection", key: key) {
                model.connectionState == .ready
            }
            model.prepareConversation()
            try await wait(on: model, seconds: 45, phase: "session creation", key: key) {
                model.selectedConversation?.isAttached == true
            }
            let sessionID = try #require(model.selectedSessionID)
            try model.send("Reply with exactly ROUTE_OK. Do not use tools or read files.")
            try await wait(on: model, seconds: 90, phase: "first real reply", key: key) {
                model.selectedConversation?.isResponding == false
            }
            try requireReply("ROUTE_OK", in: model, key: key)
            progress("first reply received")
            await model.stop()
            #expect(!model.hasActiveConnection)

            // Poison only the in-memory cache again; the next connection must reread CLI.
            settings.updateAIProvider(imported.id) {
                $0.endpoint = "https://stale.example.invalid"
                $0.model = "stale-fixture-model"
            }
            let reconnect = try resolver.resolve(agentID: "claude-acp", workspaceURL: workspace, dataDirectory: dataDirectory)
            try requireRoute(reconnect, provider: provider, key: key)
            try model.connect(configuration: reconnect)
            try await wait(on: model, seconds: 45, phase: "reconnection", key: key) {
                model.connectionState == .ready
            }
            try #require(model.canLoadSessions)
            model.selectSession(sessionID)
            try await wait(on: model, seconds: 45, phase: "history restore", key: key) {
                model.selectedConversation?.isAttached == true && model.selectedConversation?.isLoading == false
            }
            #expect(model.selectedConversation?.messages.contains { $0.role == .agent && $0.text.contains("ROUTE_OK") } == true)
            progress("reconnected and restored history")
            try model.send("Reply with exactly RESUME_OK. Do not use tools or read files.")
            try await wait(on: model, seconds: 90, phase: "resumed real reply", key: key) {
                model.selectedConversation?.isResponding == false
            }
            try requireReply("RESUME_OK", in: model, key: key)
            progress("resumed reply received")
        } catch {
            await model.stop()
            throw error
        }
        await model.stop()
        #expect(!model.hasActiveConnection)
        let persisted = String(decoding: try #require(store.data(forKey: "settings.commitMessageAI")), as: UTF8.self)
        let hasPersistedSecret = persisted.contains(key)
        #expect(!hasPersistedSecret)
        #expect(settings.agentConfigurations == bindings)
        #expect(settings.commitMessageAI.activeProviderID == provider.id)
        progress("connection closed; settings contain no credential")
    }

    private func requireRoute(_ launch: AgentLaunchConfiguration, provider: AIProviderProfile, key: String) throws {
        try #require(launch.providerEndpoint == provider.endpoint)
        try #require(launch.model == provider.model)
        try #require(launch.providerProtocol == provider.apiProtocol.rawValue)
        // Do not let assertion diagnostics interpolate the real credential.
        let keyMatches = launch.apiKey == key
        try #require(keyMatches, "The route must use the selected provider's credential")
    }

    private func writeConfiguration(_ url: URL, endpoint: String, model: String, key: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["env": [
            "ANTHROPIC_BASE_URL": endpoint, "ANTHROPIC_MODEL": model,
            "ANTHROPIC_API_KEY": key, "ANTHROPIC_AUTH_TOKEN": ""
        ]])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func wait(on model: AgentConnectionModel, seconds: Int, phase: String, key: String,
        until predicate: @escaping @MainActor @Sendable () -> Bool) async throws {
        progress("waiting for \(phase)")
        let completed = await awaitChange(on: model, timeout: .seconds(seconds)) {
            predicate() || failure(in: model) != nil
        }
        if let message = failure(in: model) {
            progress("\(phase) failed: \(message.replacingOccurrences(of: key, with: "[redacted]").prefix(500))")
        }
        try #require(completed, "Real Agent phase exceeded its local deadline")
        let succeeded = failure(in: model) == nil && predicate()
        try #require(succeeded, "Real Agent phase failed")
    }

    private func requireReply(_ marker: String, in model: AgentConnectionModel, key: String) throws {
        let replies = model.selectedConversation?.messages.filter { $0.role == .agent }.map(\.text) ?? []
        let received = replies.contains { $0.contains(marker) }
        if !received {
            progress("unexpected reply: \(replies.joined(separator: " ").replacingOccurrences(of: key, with: "[redacted]").prefix(500))")
        }
        try #require(received, "The real Agent must return the requested marker")
    }

    private func progress(_ message: String) {
        // Pipe-backed stdout is buffered; stderr keeps the harness watchdog and
        // operator informed without printing configuration JSON or credentials.
        FileHandle.standardError.write(Data("Real Agent route: \(message)\n".utf8))
    }

    private func failure(in model: AgentConnectionModel) -> String? {
        if case .failed(let message) = model.connectionState { return message }
        return model.errorMessage ?? model.selectedConversation?.errorMessage ?? model.historyError
    }
}

private final class RouteIntegrationFileManager: FileManager, @unchecked Sendable {
    private let home: URL
    init(home: URL) { self.home = home; super.init() }
    override var homeDirectoryForCurrentUser: URL { home }
}

private final class RouteIntegrationSettingsStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
