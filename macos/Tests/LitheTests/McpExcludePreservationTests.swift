import Foundation
import Testing
@testable import Lithe

@MainActor
struct McpExcludePreservationTests {
    @Test(arguments: ["", "\n", "\r\n"])
    func appendingRulePreservesNonUTF8BytesAndIsIdempotent(lineEnding: String) throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        var original = Data([0x23, 0x20, 0xFF, 0xFE, 0x80])
        original.append(contentsOf: "\r\nexisting-rule".utf8)
        original.append(contentsOf: lineEnding.utf8)
        try original.write(to: fixture.excludeURL)
        let store = fixture.store()

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        let separator = lineEnding.isEmpty ? "\n" : ""
        let expected = original + Data((separator + ".codex/config.toml\n").utf8)
        #expect(try Data(contentsOf: fixture.excludeURL) == expected)

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try Data(contentsOf: fixture.excludeURL) == expected)
    }

    @Test(
        arguments: ["\n", "\r\n", ""],
        [".codex/config.toml", "/.codex/config.toml"]
    )
    func existingRuleIsRecognizedDespiteUnrelatedNonUTF8Bytes(
        lineEnding: String, existingRule: String
    ) throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        var original = Data([0x23, 0x20, 0xFF, 0x0A])
        original.append(contentsOf: (existingRule + lineEnding).utf8)
        try original.write(to: fixture.excludeURL)
        let store = fixture.store()

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)
        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try Data(contentsOf: fixture.excludeURL) == original)
    }

    @Test(arguments: [" /.codex/config.toml", "\t.codex/config.toml"])
    func leadingWhitespaceDoesNotCountAsTheTargetRule(existingRule: String) throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        let original = Data((existingRule + "\n").utf8)
        try original.write(to: fixture.excludeURL)
        let store = fixture.store()

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)
        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try Data(contentsOf: fixture.excludeURL)
            == original + Data(".codex/config.toml\n".utf8))
    }

    @Test
    func existingExcludeReadFailureThrowsWithoutReplacingItsBytes() throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        let original = Data("# retain this policy\nprivate-assets/\n".utf8)
        try original.write(to: fixture.excludeURL)
        let store = fixture.store(failingReadURL: fixture.excludeURL)

        #expect(throws: McpConfigurationError.unreadable(fixture.excludeURL.path)) {
            try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)
        }

        #expect(try Data(contentsOf: fixture.excludeURL) == original)
    }

    @Test
    func missingExcludeIsCreatedAndRepeatedCallsKeepOneRule() throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)
        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try Data(contentsOf: fixture.excludeURL) == Data(".codex/config.toml\n".utf8))
    }

    @Test
    func ruleAppendedByAnotherEditorSurvivesPublishingTheCodexRule() throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        try Data("old-rule\n".utf8).write(to: fixture.excludeURL)
        let hook = ExcludeInterleavingHook()
        hook.beforePublish = {
            try Data("old-rule\nnew-rule\n".utf8).write(to: fixture.excludeURL)
        }
        let store = fixture.store(hook: hook)

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try String(contentsOf: fixture.excludeURL, encoding: .utf8)
            == "old-rule\nnew-rule\n.codex/config.toml\n")
    }

    @Test
    func ruleAppendedByAnotherEditorSurvivesCreatingTheExcludeFile() throws {
        let fixture = try ExcludeFixture()
        defer { fixture.cleanUp() }
        let hook = ExcludeInterleavingHook()
        hook.beforePublish = {
            try Data("external-rule\n".utf8).write(to: fixture.excludeURL)
        }
        let store = fixture.store(hook: hook)

        try store.excludeFromVersionControl(".codex/config.toml", workspace: fixture.workspace)

        #expect(try String(contentsOf: fixture.excludeURL, encoding: .utf8)
            == "external-rule\n.codex/config.toml\n")
    }
}

@MainActor
private struct ExcludeFixture {
    let workspace: URL
    var excludeURL: URL { workspace.appendingPathComponent(".git/info/exclude") }

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-exclude-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent(".git/info", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    func store(
        failingReadURL: URL? = nil,
        hook: ExcludeInterleavingHook? = nil
    ) -> MacAgentMcpConfigurationStore {
        MacAgentMcpConfigurationStore(
            core: RustCoreBridge(),
            storage: ExcludeFileStorage(
                root: workspace, failingReadURL: failingReadURL, interleaving: hook
            ),
            environment: [:]
        )
    }

    func cleanUp() {
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            Issue.record("Failed to remove temporary Git directory: \(error)")
        }
    }
}

/// Real file operations with one deterministic read failure, independent of OS permissions.
private final class ExcludeInterleavingHook: @unchecked Sendable {
    var beforePublish: (() throws -> Void)?
}

private struct ExcludeFileStorage: FileStorage {
    let root: URL
    let failingReadURL: URL?
    let interleaving: ExcludeInterleavingHook?
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
        if url.standardizedFileURL == failingReadURL?.standardizedFileURL {
            throw CocoaError(.fileReadNoPermission)
        }
        return try files.readData(from: url, options: options)
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
        if let hook = interleaving?.beforePublish {
            interleaving?.beforePublish = nil
            try hook()
        }
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
