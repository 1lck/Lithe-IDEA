import Foundation
@testable import LitheGitModule
import Testing

struct GitHistoryRewriteTests {
    @Test
    func multiSelectionKeepsItsAnchorWhenPagesAppendAndRightClickPreservesTheGroup() {
        var selection = GitHistorySelection()
        selection.select("c", visibleHashes: ["d", "c", "b"])
        selection.select("a", visibleHashes: ["d", "c", "b", "a"], range: true)
        #expect(selection.hashes == ["c", "b", "a"])
        #expect(selection.anchorHash == "c")
        selection.selectForContextMenu("b")
        #expect(selection.hashes == ["c", "b", "a"])
        #expect(selection.focusedHash == "b")
        #expect(selection.anchorHash == "c")
        selection.selectForContextMenu("d")
        #expect(selection.hashes == ["d"])
        #expect(selection.anchorHash == "d")
    }

    @Test
    func additiveSelectionCanBecomeEmptyAndFilteredRangesNeverInventHiddenCommits() {
        var selection = GitHistorySelection()
        selection.select("d", visibleHashes: ["d", "b", "a"])
        selection.select("b", visibleHashes: ["d", "b", "a"], range: true)
        #expect(selection.hashes == ["d", "b"])
        selection.select("d", visibleHashes: ["d", "b", "a"], additive: true)
        selection.select("b", visibleHashes: ["d", "b", "a"], additive: true)
        #expect(selection.hashes.isEmpty)
        #expect(selection.focusedHash == "b")
        // Core will decide whether selected commits are consecutive in the actual DAG.
        selection.select("a", visibleHashes: ["a"], range: true)
        #expect(selection.hashes == ["a"])
        #expect(selection.anchorHash == "a")
    }

    @Test
    func sharedPreviewPreservesCompleteMessagesAndTheExpectedStateToken() throws {
        struct Fixture: Decodable {
            let preview: GitHistoryRewritePreview
            let historyRewrite: GitHistoryRewriteResult
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/git/history-rewrite-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.preview.suggestedMessage == "Update example\n\nKeep the complete description.\n")
        #expect(fixture.preview.selectedCommits.first?.message == fixture.preview.suggestedMessage)
        let expected = try #require(fixture.preview.expectedState)
        let echoed = try JSONDecoder().decode(GitHistoryRewriteExpectedState.self, from: JSONEncoder().encode(expected))
        #expect(echoed == expected)
        #expect(echoed.revisions == fixture.preview.selectedCommits.map(\.hash))
        #expect(fixture.historyRewrite.mutationApplied)
        #expect(fixture.historyRewrite.outcomeKnown)
        #expect(fixture.historyRewrite.recoveryReference.hasPrefix("refs/lithe/history-recovery/"))
    }
}
