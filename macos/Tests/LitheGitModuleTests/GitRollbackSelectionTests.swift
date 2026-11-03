import Foundation
@testable import LitheGitModule
import Testing

struct GitRollbackSelectionTests {
    private let root = URL(fileURLWithPath: "/workspace")

    private func change(_ path: String, index: Character = " ", worktree: Character = "M", count: Int? = nil) -> GitChange {
        GitChange(repositoryRoot: root, path: path, originalPath: nil, indexStatus: index,
            workTreeStatus: worktree, untrackedFileCount: count)
    }

    @Test
    func checkedFilesWinOverHighlightAndEmptyHighlightIncludesAll() {
        let staged = change("checked.swift", index: "M", worktree: " ")
        let highlighted = change("highlighted.swift")
        #expect(GitRollbackSelection.initialTargets(changes: [staged, highlighted], selectedIDs: [highlighted.id]) == [staged])
        #expect(GitRollbackSelection.initialTargets(changes: [highlighted], selectedIDs: []) == [highlighted])
    }

    @Test
    func inclusionDraftIsIndependentAndCanBeEmpty() {
        let tracked = change("tracked.swift")
        let added = change("added.swift", index: "A", worktree: " ")
        var selection = GitRollbackSelection(contextID: UUID(), changes: [tracked, added], included: [tracked])
        #expect(!selection.deleteAddedFiles && !selection.hasIncludedAdditions)
        selection.toggle([added])
        #expect(selection.hasIncludedAdditions && selection.includedChanges == [tracked, added])
        selection.toggle([tracked, added])
        #expect(selection.includedChanges.isEmpty && !selection.hasIncludedAdditions)
        #expect(selection.changes == [tracked, added] && added.isStaged && !tracked.isStaged)
    }

    @Test
    func copiedDestinationAndIntentToAddKeepAdditionSafety() {
        let copy = GitChange(repositoryRoot: root, path: "copy.txt", originalPath: "source.txt",
            indexStatus: "C", workTreeStatus: " ")
        #expect(GitRollbackSelection.isAddition(copy))
        #expect(GitRollbackSelection.operationTarget(copy).pathspecs == ["copy.txt"])
        #expect(GitRollbackSelection.isAddition(change("intent.txt", worktree: "A")))
        #expect(!GitRollbackSelection.isAddition(change("conflict.txt", index: "A", worktree: "A")))
    }

    @Test
    func retainedDiskCopyNeverTurnsTrackedDeletionIntoAnAddition() {
        let deleted = change("tracked.txt", index: "D", worktree: " ")
        let retained = change("tracked.txt", index: "?", worktree: "?")
        let selection = GitRollbackSelection(contextID: UUID(), changes: [retained, deleted, deleted], included: [retained])
        #expect(selection.changes == [deleted] && selection.includedChanges == [deleted])
        #expect(!selection.hasIncludedAdditions)
    }

    @Test
    func expandedUntrackedDirectoryUsesIndividualChildrenForExclusions() {
        let directory = change("build/", index: "?", worktree: "?", count: 2)
        let children = ["build/a.o", "build/b.o"].map { change($0, index: "?", worktree: "?") }
        var selection = GitRollbackSelection(contextID: UUID(), changes: [directory] + children, included: [directory])
        #expect(selection.changes == children && selection.includedChanges == children)
        selection.toggle([children[0]])
        #expect(selection.includedChanges == [children[1]])
    }
}
