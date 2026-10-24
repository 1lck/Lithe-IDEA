import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe

/// Exercise discovery -> draft -> feature save -> Core reparse using isolated real files.
@MainActor
struct McpArgumentRoundTripTests {
    @Test func cancellingBeforeTheNativeWorkerStartsDoesNotConnect() async throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let service = try #require(fixture.mcpTools)
        let definition = McpServerDefinition(name: "cancelled", transport: .http, command: nil, args: [], env: [],
            url: "https://example.invalid/mcp", headers: [], definitionHash: "fixture")
        // Both tasks inherit MainActor: cancellation precedes the first probe
        // instruction, without a scheduling delay or a public-network fixture.
        let task = Task { try await service.probe(definition) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled probe must not publish a result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_MCP_PROBE_INTEGRATION"] == "1"))
    func publicContext7ProbeRunsOnTheNativeWorker() async throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let service = try #require(fixture.mcpTools)
        let definition = McpServerDefinition(name: "context7", transport: .http, command: nil, args: [], env: [],
            url: "https://mcp.context7.com/mcp", headers: [], definitionHash: "integration")
        // Explicit integration opt-in: verifies the real linked Swift/SDK path,
        // including proxy/TLS stack depth, without calling any remote tool.
        let result = try await service.probe(definition)
        #expect(result.tools.contains { $0.name == "resolve-library-id" })
        #expect(result.tools.contains { $0.name == "query-docs" })
    }

    @Test func renamingDoesNotBypassClaudeToolRestrictions() throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        try fixture.seed(.claudeCode, arguments: [])
        try fixture.externalPolicyChange(.claudeCode)
        let feature = fixture.feature(); feature.refresh()
        let row = try #require(feature.rows.first)
        var draft = feature.draft(for: row); draft.name = "renamed"
        #expect(!feature.save(draft))
        #expect(feature.error != nil)
        #expect(try fixture.reparse(.claudeCode).name == "alpha")
    }

    @Test func codexRenamePreservesOnlyOwnedExactToolRulesAndAllowsReenabling() throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        var draft = feature.makeDraft()
        draft.name = "alpha"; draft.command = "/bin/echo"; draft.enabledAgents = [.codex]
        try #require(feature.save(draft))
        // The user owns read's deny and allow-list; Lithe owns only write's deny.
        try fixture.codexFilters(allow: ["read", "write"], deny: ["read"])
        feature.refresh()
        feature.takeOwnership(of: try #require(feature.rows.first), agent: .codex)
        let row = try #require(feature.rows.first)
        let service = try #require(fixture.mcpTools)
        let target = McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file))
        let off = try service.setEnabled(false, tool: "write", target: target,
            snapshot: service.policy(for: target, agent: .codex, tools: ["read", "write", "outside"]))
        feature.tools.didChangePolicy?(row, off)
        service.release([off])
        var renamed = feature.draft(for: try #require(feature.rows.first)); renamed.name = "beta"
        try #require(feature.save(renamed))
        #expect(try fixture.reparse(.codex, name: "beta").name == "beta")
        let beta = try #require(feature.rows.first)
        let betaTarget = McpToolTarget(definition: beta.definition, files: beta.globalSources.map(\.file))
        let policy = try service.policy(for: betaTarget, agent: .codex, tools: ["read", "write", "outside"])
        #expect(policy.tools.first { $0.name == "write" }?.enabled == false)
        #expect(policy.tools.first { $0.name == "write" }?.editable == true)
        #expect(policy.tools.first { $0.name == "read" }?.editable == false)
        #expect(policy.tools.first { $0.name == "outside" }?.editable == false)
        let on = try service.setEnabled(true, tool: "write", target: betaTarget, snapshot: policy)
        feature.tools.didChangePolicy?(beta, on)
        service.release([on])
        #expect(on.tools.first { $0.name == "write" }?.enabled == true)
        #expect(on.tools.first { $0.name == "read" }?.enabled == false)

        // Reusing alpha must not inherit the ownership moved to beta.
        try #require(feature.save(draft))
        try fixture.codexFilters(allow: ["read", "write"], deny: ["write"])
        feature.refresh()
        let alpha = try #require(feature.rows.first { $0.name == "alpha" })
        let alphaPolicy = try service.policy(for: McpToolTarget(definition: alpha.definition,
            files: alpha.globalSources.map(\.file)), agent: .codex, tools: ["write"])
        defer { service.release([alphaPolicy]) }
        #expect(alphaPolicy.tools.first?.enabled == false)
        #expect(alphaPolicy.tools.first?.editable == false)
    }

    @Test func compactEditorFitsBothNativeAppearances() throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        let entries = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        let entry = try #require(entries.first { $0.id == "lithe.featured/playwright" })
        var draft = try #require(McpServerDraft(entry: entry)); draft.enabledAgents = Set(McpAgent.allCases)
        let directory = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/test-stability/mcp-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = McpServerEditorView(feature: feature, draft: .constant(draft), onClose: {})
                .padding(20).frame(width: 640, height: 500)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(LitheTheme.settingsSurface)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            #expect(host.fittingSize == NSSize(width: 640, height: 500))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 500); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("editor-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(arguments: McpAgent.allCases)
    func toolExclusionsRoundTripAndKeepOwnedServerRemovalWorking(agent: McpAgent) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        var draft = feature.makeDraft(); draft.name = "alpha"; draft.command = "/bin/echo"; draft.enabledAgents = [agent]
        try #require(feature.save(draft))
        let row = try #require(feature.rows.first)
        let service = try #require(fixture.mcpTools)
        let target = McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file))
        let policy = try service.policy(for: target, agent: agent, tools: ["read", "write"])
        let off = try service.setEnabled(false, tool: "write", target: target, snapshot: policy)
        #expect(off.tools.first { $0.name == "write" }?.enabled == false)
        let reopened = try service.policy(for: target, agent: agent, tools: ["read", "write"])
        #expect(reopened.tools.first { $0.name == "write" }?.enabled == false)
        let on = try service.setEnabled(true, tool: "write", target: target, snapshot: reopened)
        #expect(on.tools.allSatisfy { $0.enabled })
        service.release([off, on])
        feature.refresh()
        // Direct adapter changes intentionally do not adopt server ownership.
        // The page model advances the matching source hash after its own edit.
        let current = try #require(feature.rows.first)
        let page = feature.tools
        page.didChangePolicy?(row, off)
        page.didChangePolicy?(current, on)
        #expect(feature.rows.first?.definition.name == "alpha")
        try #require(feature.setAgent(agent, enabled: false, for: try #require(feature.rows.first)))
        #expect(feature.rows.isEmpty)
    }

    @Test(arguments: McpAgent.allCases)
    func staleToolPolicySnapshotPreservesExternalNativeEdits(agent: McpAgent) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        try fixture.seed(agent, arguments: [])
        let feature = fixture.feature(); feature.refresh()
        let row = try #require(feature.rows.first)
        let service = try #require(fixture.mcpTools)
        let target = McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file))
        let snapshot = try service.policy(for: target, agent: agent, tools: ["read"])
        try fixture.externalPolicyChange(agent)
        #expect(throws: (any Error).self) {
            try service.setEnabled(false, tool: "read", target: target, snapshot: snapshot)
        }
        let latest = try service.policy(for: target, agent: agent, tools: ["read"])
        #expect(latest.tools.first?.enabled == false)
        #expect(latest.tools.first?.editable == false)
        service.release([snapshot, latest])
    }

    @Test(arguments: ["switch", "editor", "delete"])
    func disabledToolsSurviveServerRemovalAndReopening(action: String) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        var draft = feature.makeDraft()
        draft.name = "alpha"; draft.command = "/bin/echo"
        draft.env = [McpKeyValue(key: "TOKEN", value: "fixture-secret-must-not-be-archived")]
        draft.enabledAgents = Set(McpAgent.allCases)
        try #require(feature.save(draft))
        try fixture.codexFilters(allow: ["read", "write"], deny: ["read"])
        feature.refresh()
        feature.takeOwnership(of: try #require(feature.rows.first), agent: .codex)
        let row = try #require(feature.rows.first)
        let service = try #require(fixture.mcpTools)
        let target = McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file))
        let names = ["read", "write", "outside-allowlist"]
        let policy = try service.policy(for: target, agent: .codex, tools: names)
        let off = try service.setEnabled(false, tool: "write", target: target, snapshot: policy)
        feature.tools.didChangePolicy?(row, off)
        service.release([off])
        let claudeBefore = try fixture.nativeText(.claudeCode)
        let current = try #require(feature.rows.first)
        switch action {
        case "switch": try #require(feature.setAgent(.codex, enabled: false, for: current))
        case "editor":
            var edit = feature.draft(for: current); edit.enabledAgents.remove(.codex)
            try #require(feature.save(edit))
        default: try #require(feature.delete(current))
        }
        #expect(try !fixture.nativeText(.codex).contains("mcp_servers.alpha"))
        #expect(!fixture.ledgerText().contains("fixture-secret-must-not-be-archived"))

        // A new page reads durable state, rather than the old policy snapshot.
        let reopened = fixture.feature(); reopened.refresh()
        if action == "switch" {
            try #require(reopened.setAgent(.codex, enabled: true, for: try #require(reopened.rows.first)))
        } else {
            var add = McpServerDraft(definition: row.definition)
            add.enabledAgents = Set(McpAgent.allCases)
            try #require(reopened.save(add))
        }
        let restored = try #require(reopened.rows.first)
        let restoredTarget = McpToolTarget(definition: restored.definition, files: restored.globalSources.map(\.file))
        let restoredPolicy = try service.policy(for: restoredTarget, agent: .codex, tools: names)
        defer { service.release([restoredPolicy]) }
        #expect(restoredPolicy.tools.allSatisfy { !$0.enabled })
        #expect(restoredPolicy.tools.first { $0.name == "read" }?.editable == false)
        #expect(restoredPolicy.tools.first { $0.name == "write" }?.editable == true)
        #expect(restoredPolicy.tools.first { $0.name == "outside-allowlist" }?.editable == false)
        let claude = try service.policy(for: restoredTarget, agent: .claudeCode, tools: names)
        service.release([claude])
        #expect(claude.tools.allSatisfy { $0.enabled })
        if action != "delete" { #expect(try fixture.nativeText(.claudeCode) == claudeBefore) }

        let on = try service.setEnabled(true, tool: "write", target: restoredTarget, snapshot: restoredPolicy)
        service.release([on]); reopened.tools.didChangePolicy?(restored, on)
        #expect(on.tools.first { $0.name == "write" }?.enabled == true)
        #expect(on.tools.first { $0.name == "read" }?.enabled == false)
        try #require(reopened.setAgent(.codex, enabled: false, for: try #require(reopened.rows.first)))
    }

    @Test func retainedFiltersStayWithTheirNativeProfilePath() throws {
        let ledger = ArgumentKeyValueStore()
        let first = try ArgumentFixture(ledger: ledger)
        defer { first.cleanUp() }
        let second = try ArgumentFixture(ledger: ledger)
        defer { second.cleanUp() }
        var draft = McpServerDraft(); draft.name = "alpha"; draft.command = "/bin/echo"
        draft.enabledAgents = Set(McpAgent.allCases)
        let original = first.feature()
        try #require(original.save(draft))
        try first.codexFilters(allow: [], deny: ["read"])
        original.refresh()
        original.takeOwnership(of: try #require(original.rows.first), agent: .codex)
        try #require(original.setAgent(.codex, enabled: false, for: try #require(original.rows.first)))

        let otherProfile = second.feature()
        draft.enabledAgents = [.codex]
        try #require(otherProfile.save(draft))
        #expect(try !second.nativeText(.codex).contains("enabled_tools"))
        #expect(try !second.nativeText(.codex).contains("disabled_tools"))
        try #require(otherProfile.delete(try #require(otherProfile.rows.first)))

        // Returning to the original native path restores its empty allow-list,
        // even after a different profile reused the same name and preferences.
        let reopened = first.feature(); reopened.refresh()
        try #require(reopened.setAgent(.codex, enabled: true, for: try #require(reopened.rows.first)))
        let row = try #require(reopened.rows.first)
        let service = try #require(first.mcpTools)
        let policy = try service.policy(for: McpToolTarget(definition: row.definition, files: row.globalSources.map(\.file)),
            agent: .codex, tools: ["read", "write"])
        defer { service.release([policy]) }
        #expect(policy.tools.allSatisfy { !$0.enabled && !$0.editable })
    }

    @Test(arguments: McpAgent.allCases, ["github", "deepwiki", "exa", "filesystem", "fetch", "memory"])
    func featuredSetupIsExplicitAndRoundTripsThroughNativeConfiguration(agent: McpAgent, name: String) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        let entries = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        let entry = try #require(entries.first { $0.id == "lithe.featured/\(name)" })
        var draft = try #require(McpServerDraft(entry: entry))
        #expect(draft.enabledAgents.isEmpty)
        #expect(!feature.save(draft))
        #expect(try fixture.hasConfiguration(agent) == false)
        draft.enabledAgents = [agent]
        switch draft.setup {
        case .bearerToken:
            #expect(!feature.save(draft))
            draft.headers[0].value = "Bearer "
            #expect(!feature.save(draft))
            #expect(try fixture.hasConfiguration(agent) == false)
            draft.headers[0].value = "Bearer fixture-token"
        case .allowedDirectories:
            #expect(!feature.save(draft))
            draft.argumentsText += "\nrelative-folder"
            #expect(!feature.save(draft))
            #expect(try fixture.hasConfiguration(agent) == false)
            draft.argumentsText = try #require(entry.draft).args.joined(separator: "\n") + "\n" + fixture.allowedFolder()
        case nil: break
        }
        try #require(feature.save(draft))
        let reparsed = try fixture.reparse(agent, name: name)
        #expect(reparsed.args == draft.arguments)
        #expect(reparsed.url == (draft.url.isEmpty ? nil : draft.url))
        #expect(reparsed.headers == draft.headers)
        #expect(feature.rows.first?.enabledGlobalAgents == [agent])
    }

    @Test(
        arguments: McpAgent.allCases,
        [
            [String](),
            [""],
            [" ", "\t", " \t "],
            ["", "--flag", "", " ", "\t", "line one\nline two", " padded ", ""]
        ]
    )
    func envOnlyEditPreservesOriginalArgumentArray(
        agent: McpAgent, originalArguments: [String]
    ) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        try fixture.seed(agent, arguments: originalArguments)
        let feature = fixture.feature()
        feature.refresh()
        try #require(feature.loadErrors.isEmpty)
        let row = try #require(feature.rows.first)
        #expect(row.definition.args == originalArguments)
        #expect(row.enabledGlobalAgents == [agent])
        var draft = feature.draft(for: row)

        // Leave the lossy text projection alone and change only the environment.
        draft.env = [McpKeyValue(key: "MODE", value: "after")]
        try #require(feature.save(draft))

        let reparsed = try fixture.reparse(agent)
        #expect(reparsed.args == originalArguments)
        #expect(reparsed.env == [McpKeyValue(key: "MODE", value: "after")])
        #expect(feature.loadErrors.isEmpty)
        #expect(feature.rows.first?.definition.args == originalArguments)
    }

    @Test(arguments: McpAgent.allCases)
    func argumentEditsPreserveBlankAndWhitespaceLines(agent: McpAgent) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        try fixture.seed(agent, arguments: ["before"])
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first)
        var draft = feature.draft(for: row)
        draft.argumentsText = "\nalpha\n\n \n\t\nomega\n"

        try #require(feature.save(draft))

        let reparsed = try fixture.reparse(agent)
        #expect(reparsed.args == ["", "alpha", "", " ", "\t", "omega", ""])
    }

    @Test(arguments: McpAgent.allCases)
    func clearingArgumentTextRemovesAllArguments(agent: McpAgent) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        try fixture.seed(agent, arguments: ["before", "", " "])
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first)
        var draft = feature.draft(for: row)
        draft.argumentsText = ""

        try #require(feature.save(draft))

        let reparsed = try fixture.reparse(agent)
        #expect(reparsed.args.isEmpty)
    }

    @Test(arguments: McpAgent.allCases)
    func newDraftWithEmptyArgumentTextSavesNoArguments(agent: McpAgent) throws {
        let fixture = try ArgumentFixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        var draft = feature.makeDraft()
        draft.name = "alpha"
        draft.command = "/bin/echo"
        draft.enabledAgents = [agent]

        try #require(feature.save(draft))

        let reparsed = try fixture.reparse(agent)
        #expect(reparsed.args.isEmpty)
    }
}

@MainActor
private final class ArgumentFixture: McpServerLibraryActions {
    private let root: URL
    private let store: MacAgentMcpConfigurationStore
    private let ledger: ArgumentKeyValueStore
    private lazy var toolService = MacMcpTools(core: RustCoreBridge(), store: store, ledger: ledger,
        storage: ArgumentFileStorage(root: root), environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path])

    var mcpTools: (any McpToolsManaging)? { toolService }
    var mcpRegistry: (any McpRegistryProviding)? { MacMcpRegistry(core: RustCoreBridge()) }
    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpWorkspaceURL: URL? { nil }
    var mcpLedgerStore: any KeyValueStore { ledger }

    init(ledger: ArgumentKeyValueStore = ArgumentKeyValueStore()) throws {
        self.ledger = ledger
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-arguments-\(UUID().uuidString)", isDirectory: true)
        root = directory
        store = MacAgentMcpConfigurationStore(
            core: RustCoreBridge(),
            storage: ArgumentFileStorage(root: directory),
            environment: [
                "CODEX_HOME": directory.appendingPathComponent("codex").path,
                "CLAUDE_CONFIG_DIR": directory.appendingPathComponent("claude").path
            ]
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func feature() -> McpServerLibraryFeatureModel {
        McpServerLibraryFeatureModel(model: self)
    }

    private func file(for agent: McpAgent) throws -> McpConfigurationFile {
        try #require(store.configurationFiles(workspace: nil).first { $0.agent == agent })
    }

    func seed(_ agent: McpAgent, arguments: [String]) throws {
        let file = try file(for: agent)
        let encodedArguments = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
        let content: String
        switch agent {
        case .codex:
            content = """
            [mcp_servers.alpha]
            command = "/bin/echo"
            args = \(encodedArguments)
            env = { MODE = "before" }
            """
        case .claudeCode:
            content = """
            {"mcpServers":{"alpha":{"command":"/bin/echo","args":\(encodedArguments),"env":{"MODE":"before"}}}}
            """
        }
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: file.url)
    }

    func hasConfiguration(_ agent: McpAgent) throws -> Bool {
        try store.read(file(for: agent)) != nil
    }

    func nativeText(_ agent: McpAgent) throws -> String { try store.read(file(for: agent)) ?? "" }

    func codexFilters(allow: [String], deny: [String]) throws {
        let file = try file(for: .codex)
        let encode = { (values: [String]) in String(decoding: try JSONEncoder().encode(values), as: UTF8.self) }
        let before = try nativeText(.codex)
        let header = "[mcp_servers.alpha]\n"
        try #require(before.contains(header))
        let text = before.replacingOccurrences(of: header, with: header + "enabled_tools = \(try encode(allow))\ndisabled_tools = \(try encode(deny))\n")
        try Data(text.utf8).write(to: file.url)
    }

    func ledgerText() -> String {
        ledger.data(forKey: "settings.mcpServerRegistrations").map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func allowedFolder() throws -> String {
        let directory = root.appendingPathComponent("allowed folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    func externalPolicyChange(_ agent: McpAgent) throws {
        if agent == .codex {
            let file = try file(for: agent)
            let original = try #require(try store.read(file))
            try Data((original + "\ndisabled_tools = ['read']\n").utf8).write(to: file.url)
        } else {
            let path = root.appendingPathComponent("claude/settings.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"keep":"external","permissions":{"deny":["mcp__alpha__read"]}}"#.utf8).write(to: path)
        }
    }

    func reparse(_ agent: McpAgent, name: String = "alpha") throws -> McpServerDefinition {
        let file = try file(for: agent)
        let content = try #require(try store.read(file))
        let definitions = try store.parse(file, content: content)
        try #require(definitions.count == 1)
        return try #require(definitions.first { $0.name == name })
    }

    func cleanUp() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove temporary MCP argument directory: \(error)")
        }
    }
}

private final class ArgumentKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// All directory roots stay under the fixture; ordinary file operations use the real adapter.
private struct ArgumentFileStorage: FileStorage {
    let root: URL
    private let files = MacFileStorage()

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("Caches") }
    func applicationSupportDirectory() -> URL { root.appendingPathComponent("Application Support") }
    func temporaryDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? { files.metadata(for: url) }
    func fileExists(at url: URL) -> Bool { files.fileExists(at: url) }
    func isExecutable(at url: URL) -> Bool { files.isExecutable(at: url) }
    func listDirectory(at url: URL) -> [URL] { files.listDirectory(at: url) }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        try files.readPrefix(from: url, byteCount: byteCount)
    }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        try files.readData(from: url, options: options)
    }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try files.writeData(data, to: url, options: options)
    }

    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        try files.replaceData(data, at: url, expecting: expected)
    }

    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        try files.removeData(at: url, expecting: expected)
    }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
    func removeItem(at url: URL) throws { try files.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try files.moveItem(at: sourceURL, to: destinationURL)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try files.copyItem(at: sourceURL, to: destinationURL)
    }
}
