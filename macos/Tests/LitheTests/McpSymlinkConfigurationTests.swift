import Foundation
import Testing
@testable import Lithe

@MainActor
struct McpSymlinkConfigurationTests {
    @Test(arguments: McpAgent.allCases, [false, true])
    func readsPlansAndSavesThroughTheOriginalLink(agent: McpAgent, relative: Bool) throws {
        let fixture = try SymlinkFixture(agent: agent, relative: relative)
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let source = try #require(try store.read(fixture.file))
        var server = try #require(try store.parse(fixture.file, content: source).first)
        server.args = ["after"]
        let plan = try store.planWrite(McpWriteRequest(
            source: agent.sourceName, scope: "global", projectPath: nil, content: source,
            operation: "set", server: server, name: nil, previousName: nil,
            owned: [McpOwnedEntry(
                name: server.name, definitionHash: server.definitionHash, sourceHash: server.sourceHash
            )]
        ), for: fixture.file)
        #expect(plan.conflict == nil)

        let receipt = try store.write(plan.content, to: fixture.file, replacing: source)

        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == plan.content)
        #expect(try store.read(fixture.file) == plan.content)
        #expect(try store.parse(fixture.file, content: plan.content).first?.args == ["after"])
        let backup = try #require(receipt.backupURL)
        #expect(try String(contentsOf: backup, encoding: .utf8) == source)
        try fixture.expectLinkUnchanged()
    }

    @Test(arguments: McpAgent.allCases)
    func laterWriteFailureRestoresLinkedTargetAndKeepsTheLink(agent: McpAgent) throws {
        let fixture = try SymlinkFixture(agent: agent, relative: true)
        defer { fixture.cleanUp() }
        let other = fixture.otherFile
        try fixture.seed("{}", at: other.url)
        let store = fixture.store(failingWriteURL: other.url)
        let source = try #require(try store.read(fixture.file))

        #expect(throws: McpConfigurationError.notWritable(other.url.path)) {
            _ = try store.writeBatch([
                McpConfigurationChange(file: fixture.file, source: source, content: "attempted"),
                McpConfigurationChange(file: other, source: "{}", content: "attempted")
            ])
        }

        #expect(try store.read(fixture.file) == source)
        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == source)
        #expect(try store.read(other) == "{}")
        try fixture.expectLinkUnchanged()
    }

    @Test(arguments: McpAgent.allCases)
    func targetEditsAfterPlanningArePreserved(agent: McpAgent) throws {
        let fixture = try SymlinkFixture(agent: agent, relative: false)
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let source = try #require(try store.read(fixture.file))
        try fixture.seed("external", at: fixture.target)

        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try store.write("attempted", to: fixture.file, replacing: source)
        }

        #expect(try store.read(fixture.file) == "external")
        try fixture.expectLinkUnchanged()
    }

    @Test(arguments: McpAgent.allCases)
    func invalidTargetReportsTheOriginalConfigurationPath(agent: McpAgent) throws {
        let fixture = try SymlinkFixture(agent: agent, relative: true)
        defer { fixture.cleanUp() }
        try Data([0xFF]).write(to: fixture.target)

        #expect(throws: McpConfigurationError.unreadable(fixture.file.url.path)) {
            _ = try fixture.store().read(fixture.file)
        }
        try fixture.expectLinkUnchanged()
    }

    @Test(arguments: McpAgent.allCases)
    func linkedTargetsStillEnforceTheSizeLimit(agent: McpAgent) throws {
        let fixture = try SymlinkFixture(agent: agent, relative: false)
        defer { fixture.cleanUp() }
        try Data(repeating: 0x20, count: 1024 * 1024 + 1).write(to: fixture.target)

        #expect(throws: McpConfigurationError.tooLarge) {
            _ = try fixture.store().read(fixture.file)
        }
        try fixture.expectLinkUnchanged()
    }
}

@MainActor
private struct SymlinkFixture {
    let root: URL
    let file: McpConfigurationFile
    let otherFile: McpConfigurationFile
    let target: URL
    let linkDestination: String

    init(agent: McpAgent, relative: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-symlink-\(UUID().uuidString)", isDirectory: true)
        let files = MacAgentMcpConfigurationStore(
            core: RustCoreBridge(), storage: SymlinkFileStorage(root: root), environment: [:]
        ).configurationFiles(workspace: nil)
        file = files.first { $0.agent == agent }!
        otherFile = files.first { $0.agent != agent }!
        target = root.appendingPathComponent("dotfiles/\(agent.rawValue).config")
        linkDestination = relative
            ? (agent == .codex ? "../dotfiles/" : "dotfiles/") + target.lastPathComponent
            : target.path
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let source = agent == .codex
                ? "[mcp_servers.sample]\ncommand = \"/bin/echo\"\nargs = [\"before\"]\n"
                : #"{"mcpServers":{"sample":{"command":"/bin/echo","args":["before"]}}}"#
            try Data(source.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                atPath: file.url.path, withDestinationPath: linkDestination
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func store(failingWriteURL: URL? = nil) -> MacAgentMcpConfigurationStore {
        MacAgentMcpConfigurationStore(
            core: RustCoreBridge(),
            storage: SymlinkFileStorage(root: root, failingWriteURL: failingWriteURL),
            environment: [:]
        )
    }

    func seed(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    func expectLinkUnchanged() throws {
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.url.path)
            == linkDestination)
    }

    func cleanUp() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Failed to clean up symlink fixture: \(error)") }
    }
}

private struct SymlinkFileStorage: FileStorage {
    let root: URL
    var failingWriteURL: URL? = nil
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
        if url.standardizedFileURL == failingWriteURL?.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.writeData(data, to: url, options: options)
    }

    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        if url.standardizedFileURL == failingWriteURL?.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        return try files.replaceData(data, at: url, expecting: expected)
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
