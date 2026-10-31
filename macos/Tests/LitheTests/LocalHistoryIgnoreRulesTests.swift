import Foundation
@testable import LitheLocalHistoryModule
import Testing
@testable import Lithe

/// Ignore rules, usage and clearing through the real Rust core, as Settings › Local history uses them.
struct LocalHistoryIgnoreRulesTests {
    private let operations = RustLocalHistoryOperations(core: RustCoreBridge())

    private func preview(_ path: String, patterns: [String] = [], regexes: [String] = [],
                         hidden: [String] = []) -> LocalHistoryIgnorePreview? {
        operations.ignorePreview(path: path, rules: LocalHistoryVisibilityRules(
            hiddenDirectoryNames: [], hiddenFilePatterns: hidden,
            ignorePatterns: patterns, ignoreRegexes: regexes
        ), workspaceURL: nil)
    }

    @Test
    func previewReportsInvalidRegexLinesAndTheMatchingRule() throws {
        let result = try #require(preview("src/Generated/Api.java", patterns: ["*.log", ""],
                                          regexes: ["", "(unclosed", "generated/"]))
        #expect(Array(result.regexErrors.keys) == [1])
        #expect(result.matched == .regex(index: 2))
        #expect(result.builtInIgnorePatterns.contains("**/Pods/"))
        // Without an open project Git is not asked.
        #expect(result.gitIgnored == nil)

        #expect(preview("logs/run.log", patterns: ["*.log"])?.matched == .pattern("*.log"))
        #expect(preview("ios/Pods/A/a.h")?.matched == .pattern("**/Pods/"))
        #expect(preview(".git/config")?.matched == .hidden)
        #expect(preview("src/Main.java")?.matched == nil)
    }

    @Test
    func builtInFolderRulesCanBeDeleted() {
        #expect(preview("ios/Pods/A/a.h", patterns: ["!**/Pods/"])?.matched == nil)
        #expect(preview("gen/A.java", patterns: ["**/gen/"])?.matched == .pattern("**/gen/"))
        // Showing a hidden built-in folder still leaves it out of local history.
        #expect(preview(".git/config", hidden: ["!**/.git/"])?.matched == .pattern("**/.git/"))
        #expect(preview(".git/config", patterns: ["!**/.git/"], hidden: ["!**/.git/"])?.matched == nil)
        #expect(preview("build/src/Main.java", patterns: ["!**/build/", "*.log"],
                        hidden: ["!**/build/"])?.matched == nil)
    }

    @Test
    func previewInputChangesWhenEffectiveHiddenPathsChange() {
        let path = "docs/readme.md"
        let before = LocalHistoryIgnorePreviewInput(path: path, rules: .init(
            hiddenDirectoryNames: [], hiddenFilePatterns: [], ignorePatterns: ["*.log"]
        ))
        let after = LocalHistoryIgnorePreviewInput(path: path, rules: .init(
            hiddenDirectoryNames: [], hiddenFilePatterns: ["docs/*.md"], ignorePatterns: ["*.log"]
        ))
        #expect(before != after)
        #expect(operations.ignorePreview(path: before.path, rules: before.rules, workspaceURL: nil)?.matched == nil)
        #expect(operations.ignorePreview(path: after.path, rules: after.rules, workspaceURL: nil)?.matched == .hidden)
    }

    @Test
    func clearInvalidatesAnInFlightBatchBeforeItCanWriteAnotherFile() async throws {
        let operations = ClearingHistoryOperations()
        let root = URL(fileURLWithPath: "/in-memory/history")
        let service = LocalHistoryService(workspaceURL: root,
            visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []),
            storage: ClearingHistoryStorage(), operations: operations)
        let firstRecorded = TestGate(), resumeBatch = TestGate()
        // Pause at the real inter-file suspension, clear, then resume the old batch.
        let batch = Task {
            await service.recordFiles(["first", "second"].map { root.appendingPathComponent($0) },
                                      reason: .externalChange, yieldBetweenFiles: {
                firstRecorded.open()
                _ = await resumeBatch.waitUntilOpen()
            })
        }
        defer { batch.cancel(); resumeBatch.open() }
        let reached = await firstRecorded.waitUntilOpen()
        if !reached {
            batch.cancel()
            resumeBatch.open()
            await batch.value
        }
        try #require(reached)
        #expect(operations.paths == ["first"])
        #expect(await service.clear())
        resumeBatch.open()
        await batch.value
        #expect(operations.paths.isEmpty)
        await service.recordFiles([root.appendingPathComponent("new")], reason: .externalChange)
        #expect(operations.paths == ["new"])
    }

    @Test @MainActor
    func clearCancelsQueuedSaveAndExternalWritersButAllowsNewSaves() async {
        let operations = ClearingHistoryOperations()
        let root = URL(fileURLWithPath: "/in-memory/history")
        let feature = ProjectHistoryFeatureModel(
            workspaceAccess: ClearingHistoryWorkspace(), storage: ClearingHistoryStorage(),
            localHistoryOperations: operations)
        defer { feature.reset() }
        feature.openWorkspace(at: root, visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []))
        let document = LocalHistoryDocumentSnapshot(id: UUID(), url: root.appendingPathComponent("saved"), text: "new")
        feature.recordSave(document, previousText: "old")
        feature.recordExternalChanges([root.appendingPathComponent("external")])
        #expect(await feature.clearHistory())
        #expect(!feature.hasActiveModuleWork)
        #expect(operations.paths.isEmpty)
        await feature.recordHistorySnapshot(text: "after clear", for: document.url, reason: .saved)
        #expect(operations.paths == ["saved"])
    }

    @Test
    func ignoredFilesAreNotRecordedAndClearEmptiesUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-history-ignore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let rules = LocalHistoryVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [],
                                                ignorePatterns: ["*.log"], ignoreRegexes: ["^build/"])
        func record(_ path: String) -> LocalHistoryEntryPayload? {
            operations.record(at: workspace, storageURL: storage, relativePath: path, reason: .saved,
                              content: "text\n", pruneExpired: false, visibilityRules: rules)
        }

        #expect(record("run.log") == nil)
        #expect(record("build/out.txt") == nil)
        #expect(record("src/App.swift") != nil)
        #expect(try #require(operations.usage(at: storage, limitBytes: nil)).usedBytes > 0)
        #expect(operations.usage(at: storage, limitBytes: 500 * 1024 * 1024)?.limitBytes == 500 * 1024 * 1024)

        #expect(operations.clear(at: storage))
        #expect(operations.usage(at: storage, limitBytes: nil) == LocalHistoryUsage(usedBytes: 0, limitBytes: 100 * 1024 * 1024))
        #expect(FileManager.default.fileExists(atPath: storage.path))
    }
}

private struct ClearingHistoryStorage: LocalHistoryStorage {
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/in-memory/support") }
}

private struct ClearingHistoryWorkspace: LocalHistoryWorkspaceAccess {
    func fileExists(at url: URL) -> Bool { true }
    func readFile(at workspaceURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at workspaceURL: URL, relativePath: String) -> Bool { false }
}

private final class ClearingHistoryOperations: LocalHistoryOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    var paths: [String] { lock.withLock { recordedPaths } }
    func record(at workspaceURL: URL, storageURL: URL, relativePath: String, reason: LocalHistoryReason,
                content: String?, pruneExpired: Bool, visibilityRules: LocalHistoryVisibilityRules) -> LocalHistoryEntryPayload? {
        lock.withLock { recordedPaths.append(relativePath) }
        return .init(id: "00000000-0000-0000-0000-000000000001", timestamp: 1,
                     relativePath: relativePath, reason: reason.rawValue, contentPath: "snapshot", byteCount: 1)
    }
    func clear(at storageURL: URL) -> Bool { lock.withLock { recordedPaths.removeAll() }; return true }
    func entries(at workspaceURL: URL, storageURL: URL, relativePath: String?, visibilityRules: LocalHistoryVisibilityRules) -> [LocalHistoryEntryPayload]? { [] }
    func content(at storageURL: URL, contentPath: String) -> String? { nil }
    func relocate(at storageURL: URL, sourcePath: String, destinationPath: String) -> Bool { false }
    func usage(at storageURL: URL, limitBytes: Int64?) -> LocalHistoryUsage? { nil }
    func ignorePreview(path: String?, rules: LocalHistoryVisibilityRules, workspaceURL: URL?) -> LocalHistoryIgnorePreview? { nil }
}
