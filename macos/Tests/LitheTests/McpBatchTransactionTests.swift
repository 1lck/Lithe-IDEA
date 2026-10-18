import Foundation
import Testing
@testable import Lithe

/// Injects the external save at the second write, after every preflight read.
/// There are no background tasks or timing assumptions in these race regressions.
@MainActor
struct McpBatchTransactionTests {
    @Test(arguments: [false, true])
    func laterConflictRestoresExistingOrRemovesNewFile(existing: Bool) throws {
        let fixture = try BatchFixture()
        defer { fixture.cleanUp() }
        let files = fixture.store.configurationFiles(workspace: nil)
        let first = files[0]
        let second = files[1]
        let original = existing ? "# original\nmodel = \"old\"\n" : nil
        if let original { try fixture.seed(original, at: first.url) }
        try fixture.seed("{}", at: second.url)
        fixture.store.beforeSecondWrite = { _, current in
            try fixture.seed("{\"external\":true}", at: current.url)
        }

        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try fixture.store.writeBatch([
                McpConfigurationChange(file: first, source: original, content: "model = \"new\""),
                McpConfigurationChange(file: second, source: "{}", content: "{\"new\":true}")
            ])
        }
        #expect(try fixture.store.read(first) == original)
        #expect(try fixture.store.read(second) == "{\"external\":true}")
        #expect(fixture.store.restored == [first])
    }

    @Test
    func rollbackPreservesAnExternalEditAndReportsItsPath() throws {
        let fixture = try BatchFixture()
        defer { fixture.cleanUp() }
        let files = fixture.store.configurationFiles(workspace: nil)
        let first = files[0]
        let second = files[1]
        fixture.store.beforeSecondWrite = { previous, _ in
            try fixture.seed("model = \"external\"", at: previous.url)
            throw McpConfigurationError.notWritable(second.url.path)
        }
        #expect(throws: McpConfigurationError.rollbackFailed(first.url.path)) {
            _ = try fixture.store.writeBatch([
                McpConfigurationChange(file: first, source: nil, content: "model = \"new\""),
                McpConfigurationChange(file: second, source: nil, content: "{}")
            ])
        }
        #expect(try fixture.store.read(first) == "model = \"external\"")
        #expect(try fixture.store.read(second) == nil)
    }

    @Test
    func failedLibrarySaveKeepsLedgerAndRestoresEarlierAgent() throws {
        let fixture = try BatchFixture()
        defer { fixture.cleanUp() }
        let feature = McpServerLibraryFeatureModel(model: fixture)
        var draft = feature.makeDraft()
        draft.name = "sample"
        draft.command = "/bin/echo"
        draft.enabledAgents = Set(McpAgent.allCases)
        fixture.store.beforeSecondWrite = { _, current in
            let text = current.agent == .codex ? "model = \"external\"" : "{\"external\":true}"
            try fixture.seed(text, at: current.url)
        }

        #expect(!feature.save(draft))
        #expect(feature.error == McpConfigurationError.changedOnDisk.localizedDescription)
        let first = try #require(fixture.store.written.first)
        #expect(try fixture.store.read(first) == nil)
        #expect(fixture.store.restored == [first])
        #expect(fixture.ledger.values.isEmpty)
        #expect(feature.rows.isEmpty)
    }

    @Test
    func failedProjectRegistrationDoesNotPublishEitherAgentOrLedger() throws {
        let fixture = try BatchFixture()
        defer { fixture.cleanUp() }
        let feature = McpServerLibraryFeatureModel(model: fixture)
        fixture.store.beforeSecondWrite = { _, current in
            try fixture.seed("model = \"external\"", at: current.url)
        }
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe", transport: .stdio, command: "/bin/echo", args: ["fixture"]
        ))

        if case .needsAttention = feature.litheRegistration {} else {
            Issue.record("A failed registration must report the failure")
        }
        #expect(feature.litheRegisteredAgents.isEmpty)
        let first = try #require(fixture.store.written.first)
        #expect(try fixture.store.read(first) == nil)
        #expect(fixture.store.restored == [first])
        #expect(fixture.ledger.values.isEmpty)
        #expect(fixture.store.excludeCalls == 0)
    }
}

@MainActor
private final class BatchFixture: McpServerLibraryActions {
    let root: URL
    let store: FailingBatchStore
    let ledger = BatchLedger()
    var mcpWorkspaceURL: URL? { root.appendingPathComponent("project") }
    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpLedgerStore: any KeyValueStore { ledger }

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-batch-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FailingBatchStore(base: MacAgentMcpConfigurationStore(
            core: RustCoreBridge(), storage: BatchFileStorage(root: root),
            environment: ["CODEX_HOME": root.appendingPathComponent("codex").path,
                          "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path]
        ))
    }

    func seed(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
    func cleanUp() {
        store.beforeSecondWrite = nil
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove temporary MCP directory: \(error)")
        }
    }
}

@MainActor
private final class FailingBatchStore: McpConfigurationStore {
    let base: MacAgentMcpConfigurationStore
    var written: [McpConfigurationFile] = []
    var restored: [McpConfigurationFile] = []
    var excludeCalls = 0
    var beforeSecondWrite: ((McpConfigurationFile, McpConfigurationFile) throws -> Void)?
    init(base: MacAgentMcpConfigurationStore) { self.base = base }
    func configurationFiles(workspace: URL?) -> [McpConfigurationFile] {
        base.configurationFiles(workspace: workspace)
    }
    func read(_ file: McpConfigurationFile) throws -> String? { try base.read(file) }
    func write(_ content: String, to file: McpConfigurationFile,
               replacing expected: String?) throws -> McpWriteReceipt {
        if written.count == 1 { try beforeSecondWrite?(written[0], file) }
        let receipt = try base.write(content, to: file, replacing: expected)
        written.append(file)
        return receipt
    }
    func restore(_ change: McpConfigurationChange) throws {
        try base.restore(change)
        restored.append(change.file)
    }
    func parse(_ file: McpConfigurationFile, content: String) throws -> [McpServerDefinition] {
        try base.parse(file, content: content)
    }
    func planWrite(_ request: McpWriteRequest, for file: McpConfigurationFile) throws -> McpWritePlan {
        try base.planWrite(request, for: file)
    }
    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws {
        excludeCalls += 1
        try base.excludeFromVersionControl(relativePath, workspace: workspace)
    }
}

private final class BatchLedger: KeyValueStore, @unchecked Sendable {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct BatchFileStorage: FileStorage {
    let root: URL
    private let files = MacFileStorage()
    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("Caches") }
    func applicationSupportDirectory() -> URL { root.appendingPathComponent("Support") }
    func temporaryDirectory() -> URL { root.appendingPathComponent("tmp") }
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
