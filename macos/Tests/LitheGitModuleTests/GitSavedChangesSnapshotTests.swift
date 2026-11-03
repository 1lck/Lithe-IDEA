import LitheGitTestSupport
import Foundation
import Testing
@testable import LitheGitModule

struct GitSavedChangesSnapshotTests {
    @Test func shelfVersionsKeepIndependentDiffsForTheSamePath() throws {
        let file = GitCommitFile(status: "M", path: "file.txt")
        let staged = GitSavedPatchFile(file: file, version: "Staged", base: "HEAD",
            patch: "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-base\n+staged\n")
        let working = GitSavedPatchFile(file: file, version: "Working tree", base: "Index",
            patch: "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-staged\n+working\n")
        let snapshot = GitSavedChangesSnapshot(id: "test", repositoryRoot: URL(fileURLWithPath: "/repository"), files: [staged, working])
        #expect(snapshot.versions == ["Staged", "Working tree"])
        let stagedRow = try #require(staged.document.rows.first { $0.kind == .changed })
        let workingRow = try #require(working.document.rows.first { $0.kind == .changed })
        #expect(stagedRow.rightText == "staged")
        #expect(workingRow.left == "staged")
        #expect(workingRow.rightText == "working")
    }
}
