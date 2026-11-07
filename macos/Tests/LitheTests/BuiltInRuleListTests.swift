import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// Built-in rules shown as editable lines, where deleting a line turns the rule off.
struct BuiltInRuleListTests {
    @Test
    func deletedBuiltInsAreStoredAsDisabledAndShownAgainWhenRetyped() {
        let builtIns = ["Pods", "build"]
        let stored = BuiltInRuleList.stored(lines: ["build", " gen ", "", "gen"], builtIns: builtIns)
        #expect(stored == ["gen", "!Pods"])
        #expect(BuiltInRuleList.displayed(stored: stored, builtIns: builtIns) == ["build", "gen"])
        #expect(BuiltInRuleList.stored(lines: ["Pods", "build", "gen"], builtIns: builtIns) == ["gen"])
    }

    @Test
    func disabledEntriesTurnOffBuiltInHiddenPaths() {
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: ["!**/.git/"])
        let root = URL(fileURLWithPath: "/tmp/lithe-built-in-rule-list")
        let git = root.appendingPathComponent(".git")
        #expect(!rules.isHidden(git, relativeTo: root, isDirectory: true))
        #expect(rules.hiddenFilePatterns.contains("!**/.git/"))
        #expect(FileVisibilityRules.default.isHidden(git, relativeTo: root, isDirectory: true))
    }
}
