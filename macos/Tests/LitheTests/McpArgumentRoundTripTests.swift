import Foundation
import Testing
@testable import Lithe

/// Exercise discovery -> draft -> feature save -> Core reparse using isolated real files.
@MainActor
struct McpArgumentRoundTripTests {
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
    private let ledger = ArgumentKeyValueStore()

    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpWorkspaceURL: URL? { nil }
    var mcpLedgerStore: any KeyValueStore { ledger }

    init() throws {
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

    func reparse(_ agent: McpAgent) throws -> McpServerDefinition {
        let file = try file(for: agent)
        let content = try #require(try store.read(file))
        let definitions = try store.parse(file, content: content)
        try #require(definitions.count == 1)
        return try #require(definitions.first { $0.name == "alpha" })
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
