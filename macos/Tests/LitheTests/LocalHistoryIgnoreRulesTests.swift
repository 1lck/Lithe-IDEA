import Foundation
import LitheLocalHistoryModule
import Testing
@testable import Lithe

/// Ignore rules, usage and clearing through the real Rust core, as Settings › Local history uses them.
struct LocalHistoryIgnoreRulesTests {
    private let operations = RustLocalHistoryOperations(core: RustCoreBridge())

    @Test
    func previewReportsInvalidRegexLinesAndTheMatchingRule() throws {
        let preview = try #require(operations.ignorePreview(
            path: "src/Generated/Api.java",
            ignorePatterns: ["*.log", ""],
            ignoreRegexes: ["", "(unclosed", "generated/"]
        ))
        #expect(Array(preview.regexErrors.keys) == [1])
        #expect(preview.matched == .regex(index: 2))
        #expect(preview.baselineExcludedDirectoryNames.contains("Pods"))

        #expect(operations.ignorePreview(path: "logs/run.log", ignorePatterns: ["*.log"], ignoreRegexes: [])?.matched == .pattern(index: 0))
        #expect(operations.ignorePreview(path: "ios/Pods/A/a.h", ignorePatterns: [], ignoreRegexes: [])?.matched == .baselineExcluded(directory: "Pods"))
        #expect(operations.ignorePreview(path: ".git/config", ignorePatterns: [], ignoreRegexes: [])?.matched == .hidden)
        #expect(operations.ignorePreview(path: "src/Main.java", ignorePatterns: [], ignoreRegexes: [])?.matched == nil)
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
        #expect(try #require(operations.usage(at: storage)).usedBytes > 0)

        #expect(operations.clear(at: storage))
        #expect(operations.usage(at: storage) == LocalHistoryUsage(usedBytes: 0, limitBytes: 100 * 1024 * 1024))
        #expect(FileManager.default.fileExists(atPath: storage.path))
    }
}
