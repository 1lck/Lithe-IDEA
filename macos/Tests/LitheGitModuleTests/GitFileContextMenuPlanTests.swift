import Foundation
@testable import LitheGitModule
import Testing

@Suite("Git file context menu plan")
struct GitFileContextMenuPlanTests {
    private func makeChange(
        indexStatus: Character,
        workTreeStatus: Character,
        canToggleStaging: Bool = true
    ) -> GitChange {
        GitChange(
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            path: "src/App.java",
            originalPath: nil,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            canToggleStaging: canToggleStaging
        )
    }

    @Test("No change entry hides every action")
    func hidesWithoutChange() {
        let plan = GitFileContextMenuPlan(change: nil)
        #expect(plan.showsAdd == false)
        #expect(plan.showsStageAndOpenCommit == false)
    }

    @Test("Unstaged modification keeps Add")
    func unstagedModification() {
        let plan = GitFileContextMenuPlan(change: makeChange(indexStatus: " ", workTreeStatus: "M"))
        #expect(plan.showsAdd == true)
        #expect(plan.showsStageAndOpenCommit == true)
    }

    @Test("Staged entry hides Add because staging again is a no-op")
    func stagedEntry() {
        let plan = GitFileContextMenuPlan(change: makeChange(indexStatus: "M", workTreeStatus: " "))
        #expect(plan.showsAdd == false)
        #expect(plan.showsStageAndOpenCommit == true)
    }

    @Test("Untracked file can be added and committed")
    func untrackedFile() {
        let plan = GitFileContextMenuPlan(change: makeChange(indexStatus: "?", workTreeStatus: "?"))
        #expect(plan.showsAdd == true)
        #expect(plan.showsStageAndOpenCommit == true)
    }

    @Test("Add honors the canToggleStaging gate")
    func stagingGate() {
        let plan = GitFileContextMenuPlan(
            change: makeChange(indexStatus: " ", workTreeStatus: "M", canToggleStaging: false)
        )
        #expect(plan.showsAdd == false)
        #expect(plan.showsStageAndOpenCommit == true)
    }
}
