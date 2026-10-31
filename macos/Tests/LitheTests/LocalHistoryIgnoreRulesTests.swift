import Foundation
import LitheLocalHistoryModule
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
