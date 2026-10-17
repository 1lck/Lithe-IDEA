import Foundation
import Testing
@testable import Lithe

/// End-to-end library behavior against real files in a temporary home.
///
/// Core still plans every edit; these tests verify the application merge,
/// ownership ledger, backups and project registration around it.
@MainActor
struct McpServerLibraryTests {
    @Test
    func discoversSameDefinitionFromBothAgentsAsOneRow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {
          "numStartups": 12,
          "mcpServers": {
            "alpha": {"command": "/bin/echo", "args": ["-y", "alpha"], "env": {"TOKEN": "secret"}}
          }
        }
        """)
        try fixture.seedCodex("""
        # keep this comment
        model = "gpt-5"

        [mcp_servers.alpha]
        command = "/bin/echo"
        args = ["-y", "alpha"]
        env = { TOKEN = "secret" }
        """)

        let feature = fixture.feature()
        feature.refresh()

        #expect(feature.loadErrors.isEmpty)
        #expect(feature.rows.count == 1)
        let row = try #require(feature.rows.first)
        #expect(row.name == "alpha")
        #expect(row.enabledGlobalAgents == Set(McpAgent.allCases))
        #expect(row.hasDefinitionConflict == false)
        #expect(row.ownedGlobalAgents.isEmpty)
    }

    @Test
    func takingOwnershipEnablesRemovingAnExternallyCreatedEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["keep-me"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first)

        #expect(feature.setAgent(.claudeCode, enabled: false, for: row) == false)
        #expect(feature.error?.contains("outside Lithe") == true)
        #expect(try fixture.claudeText().contains("keep-me"))

        feature.error = nil
        feature.takeOwnership(of: row, agent: .claudeCode)
        let owned = try #require(feature.rows.first)
        #expect(owned.ownedGlobalAgents == [.claudeCode])
        #expect(feature.setAgent(.claudeCode, enabled: false, for: owned))

        let updated = try fixture.claudeText()
        #expect(updated.contains("alpha") == false)
        let object = try JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any]
        let root = try #require(object)
        let servers = root["mcpServers"] as? [String: Any]
        #expect(servers?.isEmpty == true)
    }

    @Test
    func editsAnExternallyCreatedEntryWhileTheDisplayedDefinitionIsCurrent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["before"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "alpha" })
        #expect(row.ownedGlobalAgents.isEmpty)

        var draft = feature.draft(for: row)
        draft.argumentsText = "after"
        #expect(feature.save(draft))
        let updated = try fixture.claudeText()
        #expect(updated.contains("after"))
        #expect(updated.contains("before") == false)

        // A row captured before an external edit must not overwrite that edit.
        let stale = try #require(feature.rows.first { $0.name == "alpha" })
        var staleDraft = feature.draft(for: stale)
        try fixture.write(
            "{\"mcpServers\": {\"alpha\": {\"command\": \"/bin/echo\", \"args\": [\"external\"]}}}",
            to: fixture.claudeURL
        )
        staleDraft.argumentsText = "stale-write"
        #expect(feature.save(staleDraft) == false)
        #expect(feature.error?.contains("outside Lithe") == true)
        let untouched = try fixture.claudeText()
        #expect(untouched.contains("external"))
        #expect(untouched.contains("stale-write") == false)
    }

    @Test
    func addsAndEditsOneDefinitionInBothAgentFilesWithoutLosingFormatting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {
          "numStartups": 12,
          "mcpServers": {}
        }
        """)
        try fixture.seedCodex("""
        # keep this comment
        model = "gpt-5"

        [mcp_servers.existing]
        command = "/bin/true"
        """)

        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "gamma"
        draft.transport = .stdio
        draft.command = "/bin/echo"
        draft.argumentsText = "hello world\n--flag"
        draft.env = [McpKeyValue(key: "TOKEN", value: "abc")]
        draft.enabledAgents = Set(McpAgent.allCases)

        #expect(feature.save(draft))
        #expect(feature.lastBackupURL != nil)

        let claude = try fixture.claudeText()
        #expect(claude.contains("\"numStartups\": 12"))
        #expect(claude.contains("\"gamma\""))
        #expect(claude.contains("hello world"))
        let codex = try fixture.codexText()
        #expect(codex.contains("# keep this comment"))
        #expect(codex.contains("[mcp_servers.existing]"))
        #expect(codex.contains("[mcp_servers.gamma]"))
        #expect(codex.contains("hello world"))

        let added = try #require(feature.rows.first { $0.name == "gamma" })
        #expect(added.ownedGlobalAgents == Set(McpAgent.allCases))

        // Editing the owned definition replaces it in both files and records
        // the fresh hash, so removing it needs no second adoption.
        var edited = feature.draft(for: added)
        edited.argumentsText = "updated"
        #expect(feature.save(edited))
        let editedCodex = try fixture.codexText()
        let editedClaude = try fixture.claudeText()
        #expect(editedCodex.contains("updated"))
        #expect(editedClaude.contains("updated"))
        let updated = try #require(feature.rows.first { $0.name == "gamma" })
        #expect(feature.delete(updated))
        let deletedCodex = try fixture.codexText()
        let deletedClaude = try fixture.claudeText()
        #expect(deletedCodex.contains("gamma") == false)
        #expect(deletedClaude.contains("gamma") == false)
        #expect(deletedCodex.contains("[mcp_servers.existing]"))
    }

    @Test
    func projectRegistrationWritesBothAgentsAndCleansUpOnDisable() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"global": {"command": "/bin/true"}}}
        """)
        let feature = fixture.feature()
        feature.refresh()

        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))

        #expect(feature.litheRegistration == .registered)
        #expect(feature.litheRegisteredAgents == Set(McpAgent.allCases))
        let claude = try fixture.claudeText()
        #expect(claude.contains("\"global\""))
        #expect(claude.contains("fixture"))
        let codexProjectURL = fixture.workspace.appendingPathComponent(".codex/config.toml")
        let codex = try fixture.text(at: codexProjectURL)
        #expect(codex.contains("[mcp_servers.lithe]"))
        let exclude = try fixture.text(at: fixture.workspace.appendingPathComponent(".git/info/exclude"))
        #expect(exclude.contains(".codex/config.toml"))

        feature.unregisterLitheServer()

        #expect(feature.litheRegistration == .inactive)
        let unregisteredClaude = try fixture.claudeText()
        let unregisteredCodex = try fixture.text(at: codexProjectURL)
        #expect(unregisteredClaude.contains("fixture") == false)
        #expect(unregisteredCodex.contains("[mcp_servers.lithe]") == false)
        #expect(unregisteredClaude.contains("\"global\""))
    }

    @Test
    func externallyModifiedProjectEntryIsKeptAndReported() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))
        #expect(feature.litheRegistration == .registered)

        // The Agent's project Codex entry is edited outside Lithe.
        try fixture.write(
            """
            [mcp_servers.lithe]
            command = "/usr/local/bin/other"
            """,
            to: fixture.workspace.appendingPathComponent(".codex/config.toml")
        )

        feature.unregisterLitheServer()

        if case .needsAttention(let message) = feature.litheRegistration {
            #expect(message.contains("outside Lithe"))
        } else {
            Issue.record("Expected a registration conflict")
        }
        let kept = try fixture.text(at: fixture.workspace.appendingPathComponent(".codex/config.toml"))
        #expect(kept.contains("/usr/local/bin/other"))
    }
}

@MainActor
private final class LibraryActionsFixture: McpServerLibraryActions {
    let store: MacAgentMcpConfigurationStore
    var mcpWorkspaceURL: URL?
    let ledger = LibraryTestKeyValueStore()

    init(store: MacAgentMcpConfigurationStore, workspace: URL?) {
        self.store = store
        mcpWorkspaceURL = workspace
    }

    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpLedgerStore: any KeyValueStore { ledger }
}

private final class LibraryTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct LibraryTestFileStorage: FileStorage {
    let root: URL

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("Caches", isDirectory: true) }
    func applicationSupportDirectory() -> URL {
        root.appendingPathComponent("Application Support", isDirectory: true)
    }
    func temporaryDirectory() -> URL { root.appendingPathComponent("tmp", isDirectory: true) }

    func metadata(for url: URL) -> FileMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        return FileMetadata(
            byteCount: (attributes[.size] as? NSNumber)?.intValue,
            modificationDate: attributes[.modificationDate] as? Date,
            isRegularFile: type == .typeRegular,
            isDirectory: type == .typeDirectory,
            isWritable: FileManager.default.isWritableFile(atPath: url.path)
        )
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func listDirectory(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []
    }

    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        try Data(contentsOf: url).prefix(byteCount)
    }

    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        try Data(contentsOf: url, options: options)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let workspace: URL
    let claudeHome: URL
    let codexHome: URL
    private let actions: LibraryActionsFixture

    init(workspace: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        codexHome = root.appendingPathComponent("codex", isDirectory: true)
        self.workspace = root.appendingPathComponent("project", isDirectory: true)
        if workspace {
            try FileManager.default.createDirectory(
                at: self.workspace.appendingPathComponent(".git/info", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let storage = LibraryTestFileStorage(root: root)
        actions = LibraryActionsFixture(
            store: MacAgentMcpConfigurationStore(
                core: RustCoreBridge(),
                storage: storage,
                environment: [
                    "CLAUDE_CONFIG_DIR": claudeHome.path,
                    "CODEX_HOME": codexHome.path
                ]
            ),
            workspace: workspace ? self.workspace : nil
        )
    }

    func feature() -> McpServerLibraryFeatureModel {
        McpServerLibraryFeatureModel(model: actions)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var claudeURL: URL { claudeHome.appendingPathComponent(".claude.json") }
    var codexURL: URL { codexHome.appendingPathComponent("config.toml") }

    func seedClaude(_ text: String) throws { try write(text, to: claudeURL) }
    func seedCodex(_ text: String) throws { try write(text, to: codexURL) }
    func claudeText() throws -> String { try text(at: claudeURL) }
    func codexText() throws -> String { try text(at: codexURL) }

    func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
