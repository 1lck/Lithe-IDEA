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

    @Test
    func removesOnlyThePlannedSnapshot() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try fixture.write("snapshot")

        #expect(try fixture.storage.removeData(
            at: fixture.url, expecting: Data("stale".utf8)
        ) == false)
        #expect(try fixture.text() == "snapshot")

        #expect(try fixture.storage.removeData(
            at: fixture.url, expecting: Data("snapshot".utf8)
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.url.path) == false)

        #expect(try fixture.storage.removeData(
            at: fixture.url, expecting: Data("snapshot".utf8)
        ) == false)
        #expect(try fixture.entries() == [])
    }

    @Test
    func refusesToReplaceANonRegularDestination() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.url, withIntermediateDirectories: true
        )

        #expect(try fixture.storage.replaceData(
            Data("attempted".utf8), at: fixture.url, expecting: Data("snapshot".utf8)
        ) == false)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fixture.url.path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        #expect(try fixture.entries() == ["config.toml"])
    }

    /// A writer that saves after the destination check but before the rollback
    /// exchange must not have its bytes swapped into the temporary file and
    /// then deleted by the defer.
    @Test
    func rollbackPreservesASaveThatLandsAfterTheDestinationCheck() throws {
#if DEBUG
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try fixture.write("external-b")
        var storage = MacFileStorage()
        let target = fixture.url
        let newer = Data("external-c".utf8)
        storage.beforeRollbackExchangeForTesting = {
            try? newer.write(to: target)
        }

        var retained: FileStorageRetainedCopyError?
        do {
            _ = try storage.replaceData(
                Data("published-p".utf8), at: fixture.url, expecting: Data("planned-a".utf8)
            )
        } catch let error as FileStorageRetainedCopyError {
            retained = error
        }
        let error = try #require(retained)
        #expect(error.retainedPath.contains(".config.toml.lithe-"))
        // The rollback exchange displaced C. It must be kept on disk instead
        // of being deleted together with the temporary file.
        let names = try fixture.entries()
        let keptName = try #require(names.first { $0.hasPrefix(".config.toml.lithe-") })
        let keptURL = fixture.root.appendingPathComponent(keptName)
        #expect(try String(contentsOf: keptURL, encoding: .utf8) == "external-c")
        #expect(try fixture.text() == "external-b")
#else
        Issue.record("This regression requires DEBUG test hooks")
#endif
    }

    @Test
    func stagesTheTemporaryFileOwnerOnly() throws {
#if DEBUG
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try fixture.write("snapshot")
        var storage = MacFileStorage()
        let root = fixture.root
        let observed = ObservedFileMode()
        storage.afterPreparingTemporaryForTesting = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            guard let name = names.first(where: { $0.hasPrefix(".config.toml.lithe-") }) else {
                return
            }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(name).path
            )
            observed.permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        }

        #expect(try storage.replaceData(
            Data("next".utf8), at: fixture.url, expecting: Data("snapshot".utf8)
        ))
        #expect(observed.permissions == 0o600)
#else
        Issue.record("This regression requires DEBUG test hooks")
#endif
    }

    @Test
    func unsupportedExchangeFailsClosedWithoutTouchingTheFile() throws {
#if DEBUG
        let fixture = try ReplacementFixture()
        defer { fixture.cleanUp() }
        try fixture.write("snapshot")
        var storage = MacFileStorage()
        storage.unsupportedExchangeForTesting = true

        #expect(throws: CocoaError.self) {
            _ = try storage.replaceData(
                Data("next".utf8), at: fixture.url, expecting: Data("snapshot".utf8)
            )
        }
        #expect(throws: CocoaError.self) {
            _ = try storage.removeData(at: fixture.url, expecting: Data("snapshot".utf8))
        }
        #expect(try fixture.text() == "snapshot")
        #expect(try fixture.entries() == ["config.toml"])
#else
        Issue.record("This regression requires DEBUG test hooks")
#endif
    }
}

private final class ObservedFileMode: @unchecked Sendable {
    var permissions: Int?
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

    // Store-level interleaving must exercise the production compare-and-publish
    // path, not a protocol fallback that happens to have the same outcome.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        try files.replaceData(data, at: url, expecting: expected)
    }

    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        try files.removeData(at: url, expecting: expected)
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

/// A feature-level save that fails in the conditional publish stage (after the
/// snapshot check and backup) must restore earlier writes and publish no ledger.
@MainActor
struct McpFeatureBatchFailureTests {
    @Test
    func failedPublishAfterBackupRestoresTheOtherAgentAndKeepsTheLedger() throws {
        let fixture = try ReplaceFailureFixture(claude: "{\"mcpServers\": {}}")
        defer { fixture.cleanUp() }
        let feature = McpServerLibraryFeatureModel(model: fixture)
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "sample"
        draft.command = "/bin/echo"
        draft.enabledAgents = Set(McpAgent.allCases)
        // The first file publishes; the second hits changedOnDisk inside the
        // conditional publish, after its preflight check and backup.
        fixture.failures.failOnCall = 2

        #expect(feature.save(draft) == false)
        #expect(feature.error == McpConfigurationError.changedOnDisk.localizedDescription)
        #expect(try fixture.store.read(fixture.claudeFile) == "{\"mcpServers\": {}}")
        #expect(!FileManager.default.fileExists(atPath: fixture.codexURL.path))
        #expect(fixture.ledger.values.isEmpty)
        #expect(feature.rows.isEmpty)
    }
}

@MainActor
private final class ReplaceFailureFixture: McpServerLibraryActions {
    let root: URL
    let store: MacAgentMcpConfigurationStore
    let ledger = WriteProtectionLedger()
    let failures = ReplaceFailureBox()
    var mcpWorkspaceURL: URL? { nil }
    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpLedgerStore: any KeyValueStore { ledger }

    init(claude: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-feature-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        store = MacAgentMcpConfigurationStore(
            core: RustCoreBridge(),
            storage: ReplaceFailureFileStorage(root: root, failures: failures),
            environment: [
                "CODEX_HOME": root.appendingPathComponent("codex").path,
                "CLAUDE_CONFIG_DIR": claudeHome.path
            ]
        )
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try Data(claude.utf8).write(to: claudeURL)
    }

    var claudeURL: URL { root.appendingPathComponent("claude/.claude.json") }
    var codexURL: URL { root.appendingPathComponent("codex/config.toml") }
    var claudeFile: McpConfigurationFile {
        store.configurationFiles(workspace: nil).first {
            $0.agent == .claudeCode && $0.scope == .global
        }!
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class WriteProtectionLedger: KeyValueStore, @unchecked Sendable {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class ReplaceFailureBox: @unchecked Sendable {
    var replaceCalls = 0
    var failOnCall: Int?
}

private struct ReplaceFailureFileStorage: FileStorage {
    let root: URL
    let failures: ReplaceFailureBox
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
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        failures.replaceCalls += 1
        if failures.replaceCalls == failures.failOnCall { return false }
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

/// Batch rollback must keep the retained-copy location when it aggregates
/// failures, otherwise the user cannot find the newest external save.
@MainActor
struct McpBatchRollbackDetailTests {
    @Test
    func rollbackFailureReportsTheRetainedCopyPath() throws {
        let first = McpConfigurationFile(
            agent: .claudeCode, scope: .global,
            url: URL(fileURLWithPath: "/tmp/lithe-first.json"), projectPath: nil
        )
        let second = McpConfigurationFile(
            agent: .codex, scope: .global,
            url: URL(fileURLWithPath: "/tmp/lithe-second.toml"), projectPath: nil
        )
        let store = RetainedRollbackStore(files: [first, second])

        do {
            _ = try store.writeBatch([
                McpConfigurationChange(file: first, source: "old-first", content: "new-first"),
                McpConfigurationChange(file: second, source: "old-second", content: "new-second")
            ])
            Issue.record("Expected a rollback failure")
        } catch let error as McpConfigurationError {
            guard case .rollbackFailed(let details) = error else {
                Issue.record("Expected rollbackFailed, got \(error)")
                return
            }
            #expect(details.contains(first.url.path))
            #expect(details.contains("/tmp/lithe-first.json.lithe-recovery"))
        }
    }

    @Test
    func failedWriteRecoveryPathSurvivesARollbackFailure() throws {
        let first = McpConfigurationFile(
            agent: .claudeCode, scope: .global,
            url: URL(fileURLWithPath: "/tmp/lithe-first.json"), projectPath: nil
        )
        let second = McpConfigurationFile(
            agent: .codex, scope: .global,
            url: URL(fileURLWithPath: "/tmp/lithe-second.toml"), projectPath: nil
        )
        let store = RetainedRollbackStore(
            files: [first, second],
            writeError: .retainedCopy(
                destination: second.url.path,
                retained: second.url.path + ".lithe-write"
            ),
            restoreError: .changedOnDisk
        )

        do {
            _ = try store.writeBatch([
                McpConfigurationChange(file: first, source: "old-first", content: "new-first"),
                McpConfigurationChange(file: second, source: "old-second", content: "new-second")
            ])
            Issue.record("Expected a rollback failure")
        } catch let error as McpConfigurationError {
            guard case .rollbackFailed(let details) = error else {
                Issue.record("Expected rollbackFailed, got \(error)")
                return
            }
            #expect(details.contains(first.url.path))
            #expect(details.contains("/tmp/lithe-second.toml.lithe-write"))
        }
    }
}

@MainActor
private final class RetainedRollbackStore: McpConfigurationStore {
    let files: [McpConfigurationFile]
    let writeError: McpConfigurationError?
    let restoreError: McpConfigurationError?

    init(
        files: [McpConfigurationFile],
        writeError: McpConfigurationError? = nil,
        restoreError: McpConfigurationError? = nil
    ) {
        self.files = files
        self.writeError = writeError
        self.restoreError = restoreError
    }

    func configurationFiles(workspace: URL?) -> [McpConfigurationFile] { files }

    func read(_ file: McpConfigurationFile) throws -> String? {
        file == files[0] ? "old-first" : "old-second"
    }

    func write(
        _ content: String, to file: McpConfigurationFile, replacing expected: String?
    ) throws -> McpWriteReceipt {
        if file == files[1] {
            throw writeError ?? McpConfigurationError.notWritable(file.url.path)
        }
        return McpWriteReceipt(backupURL: nil)
    }

    func restore(_ change: McpConfigurationChange) throws {
        throw restoreError ?? McpConfigurationError.retainedCopy(
            destination: change.file.url.path,
            retained: change.file.url.path + ".lithe-recovery"
        )
    }

    func parse(
        _ file: McpConfigurationFile, content: String
    ) throws -> [McpServerDefinition] {
        throw McpConfigurationError.unavailable
    }

    func planWrite(
        _ request: McpWriteRequest, for file: McpConfigurationFile
    ) throws -> McpWritePlan {
        throw McpConfigurationError.unavailable
    }

    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws {
        throw McpConfigurationError.unavailable
    }
}
