import Foundation
import Testing
import LitheGitModule
@testable import Lithe

@Suite("Commit file selection")
struct GitChangeSelectionTests {
    @Test func commandTogglesAndPlainClickReplacesSelection() {
        var selection = GitChangeSelection()
        let rows = ["a", "b", "c"]
        selection.select("a", orderedIDs: rows, command: false, shift: false)
        selection.select("c", orderedIDs: rows, command: true, shift: false)
        #expect(selection.ids == ["a", "c"])
        selection.select("a", orderedIDs: rows, command: true, shift: false)
        #expect(selection.ids == ["c"])
        selection.select("b", orderedIDs: rows, command: false, shift: false)
        #expect(selection.ids == ["b"])
    }

    @Test func shiftRangeUsesVisibleOrderAndKeepsAnchor() {
        var selection = GitChangeSelection()
        let rows = ["d", "b", "a", "c"]
        selection.select("a", orderedIDs: rows, command: false, shift: false)
        selection.select("d", orderedIDs: rows, command: false, shift: true)
        #expect(selection.ids == ["d", "b", "a"])
        selection.select("c", orderedIDs: rows, command: false, shift: true)
        #expect(selection.ids == ["a", "c"])
        selection.select("d", orderedIDs: rows, command: true, shift: true)
        #expect(selection.ids == Set(rows))
    }

    @Test func removedAnchorFallsBackToClickedRow() {
        var selection = GitChangeSelection()
        selection.select("a", orderedIDs: ["a", "b"], command: false, shift: false)
        selection.retain(["b", "c"])
        #expect(selection.ids.isEmpty)
        #expect(selection.anchor == nil)
        selection.select("c", orderedIDs: ["b", "c"], command: false, shift: true)
        #expect(selection.ids == ["c"])
        selection.select("missing", orderedIDs: ["b", "c"], command: true, shift: false)
        #expect(selection.ids == ["c"])
    }

    @Test func actionsUseSelectionInsteadOfPreviouslyPreviewedFile() {
        let root = URL(fileURLWithPath: "/test-repository")
        let changes = ["a", "b", "c"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil,
                      indexStatus: " ", workTreeStatus: "M")
        }
        let ids = changes.map(\.id)
        var selection = GitChangeSelection()
        selection.select(ids[0], orderedIDs: ids, command: false, shift: false)
        selection.select(ids[1], orderedIDs: ids, command: true, shift: false)
        #expect(selection.actionTargets(in: changes, clicked: changes[1]) == Array(changes.prefix(2)))
        selection.select(ids[0], orderedIDs: ids, command: true, shift: false)
        #expect(selection.actionTargets(in: changes) == [changes[1]])
        #expect(selection.actionTargets(in: changes, clicked: changes[2]) == [changes[2]])
        #expect(selection.actionTargets(in: [changes[0]]).isEmpty)
        selection.select(ids[1], orderedIDs: ids, command: true, shift: false)
        #expect(selection.actionTargets(in: changes).isEmpty)
    }

}
