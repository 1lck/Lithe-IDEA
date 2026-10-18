import Foundation
import Testing
@testable import Lithe

/// Regression coverage for the window between the preflight snapshot check and
/// the final publish. The backup runs inside that window; an external save that
/// lands there must win over the in-flight write instead of being overwritten.
@MainActor
struct McpWriteProtectionTests {
    @Test(arguments: McpAgent.allCases)
    func externalSaveDuringBackupIsPreserved(agent: McpAgent) throws {
        let fixture = try WriteProtectionFixture(agent: agent)
        defer { fixture.cleanUp() }
        let source = try #require(try fixture.store.read(fixture.file))
        fixture.hooks.afterBackup = { try? fixture.seed(fixture.externalText) }

        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try fixture.store.write("attempted", to: fixture.file, replacing: source)
        }
        #expect(try fixture.store.read(fixture.file) == fixture.externalText)
    }

    @Test(arguments: McpAgent.allCases)
    func fileCreatedBeforePublishIsNotReplaced(agent: McpAgent) throws {
        let fixture = try WriteProtectionFixture(agent: agent, seeded: false)
        defer { fixture.cleanUp() }
        #expect(try fixture.store.read(fixture.file) == nil)
        fixture.hooks.beforeDirectoryCreation = { try? fixture.seed(fixture.externalText) }

        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try fixture.store.write("attempted", to: fixture.file, replacing: nil)
        }
        #expect(try fixture.store.read(fixture.file) == fixture.externalText)
    }
}

/// The platform storage performs the final comparison inside an atomic
/// exchange, so a stale snapshot is restored rather than accepted.
@MainActor
struct FileStorageReplacementTests {
    @Test
    func publishesOnlyThePlannedSnapshot() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try fixture.write("snapshot")

        // A differently sized external write is rejected by the size guard.
        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: Data("stale".utf8)
        ) == false)
        #expect(try fixture.text() == "snapshot")
        // The same size still requires equal bytes.
        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: Data("snapshut".utf8)
        ) == false)
        #expect(try fixture.text() == "snapshot")

        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: Data("snapshot".utf8)
        ))
        #expect(try fixture.text() == "attempted")
        // Failed and successful exchanges must not leave temporary files.
        #expect(try fixture.entries() == ["config.toml"])
    }

    @Test
    func doesNotReplaceAFileThatAppearedAfterPlanning() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }

        // A missing file cannot satisfy a snapshot precondition.
        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: Data("missing".utf8)
        ) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path) == false)

        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: nil
        ))
        #expect(try fixture.text() == "attempted")

        #expect(try fixture.storage.replaceData(
            Data("second".utf8), at: fixture.url, expecting: nil
        ) == false)
        #expect(try fixture.text() == "attempted")
        #expect(try fixture.entries() == ["config.toml"])
    }
}

@MainActor
private final class WriteProtectionFixture {
    let root: URL
    let file: McpConfigurationFile
    let store: MacAgentMcpConfigurationStore
    let hooks = InterleavingHooks()
    let externalText: String

    init(agent: McpAgent, seeded: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-write-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MacAgentMcpConfigurationStore(
            core: RustCoreBridge(),
            storage: InterleavingFileStorage(root: root, hooks: hooks),
            environment: [
                "CODEX_HOME": root.appendingPathComponent("codex").path,
                "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path
            ]
        )
        file = store.configurationFiles(workspace: nil).first {
            $0.agent == agent && $0.scope == .global
        }!
        externalText = switch agent {
        case .codex:
            "[mcp_servers.external]\ncommand = \"/bin/false\"\n"
        case .claudeCode:
            #"{"mcpServers":{"external":{"command":"/bin/false"}}}"#
        }
        if seeded { try seed(Self.sourceText(for: agent)) }
    }

    func seed(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file.url)
    }

    func cleanUp() {
        hooks.afterBackup = nil
        hooks.beforeDirectoryCreation = nil
        try? FileManager.default.removeItem(at: root)
    }

    private static func sourceText(for agent: McpAgent) -> String {
        switch agent {
        case .codex:
            "[mcp_servers.sample]\ncommand = \"/bin/echo\"\n"
        case .claudeCode:
            #"{"mcpServers":{"sample":{"command":"/bin/echo"}}}"#
        }
    }
}

/// Runs the external save synchronously at an explicit point in the write
/// sequence; there are no threads, sleeps or timing assumptions.
private final class InterleavingHooks: @unchecked Sendable {
    var afterBackup: (() -> Void)?
    var beforeDirectoryCreation: (() -> Void)?
}

private struct InterleavingFileStorage: FileStorage {
    let root: URL
    let hooks: InterleavingHooks
    private let files = MacFileStorage()

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("Caches", isDirectory: true) }
    func applicationSupportDirectory() -> URL {
        root.appendingPathComponent("Application Support", isDirectory: true)
    }
    func temporaryDirectory() -> URL { root.appendingPathComponent("tmp", isDirectory: true) }
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

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        // The store prepares the destination directory after backing up and
        // before publishing, so this is the new-file interleaving point.
        if let hook = hooks.beforeDirectoryCreation {
            hooks.beforeDirectoryCreation = nil
            hook()
        }
        try files.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func removeItem(at url: URL) throws { try files.removeItem(at: url) }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try files.moveItem(at: sourceURL, to: destinationURL)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try files.copyItem(at: sourceURL, to: destinationURL)
        if let hook = hooks.afterBackup {
            hooks.afterBackup = nil
            hook()
        }
    }
}

@MainActor
private final class ReplacementFixture {
    let root: URL
    let url: URL
    let storage = MacFileStorage()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("config.toml")
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    func text() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
