import Foundation
@testable import LitheGitModule
import Testing

struct GitInteractiveRebaseTests {
    @Test
    func defaultSquashAfterEditIsNotSentAsAStaleMessageOverride() {
        var plan = GitRebasePlanDraft(commits: [
            GitHistoryRewriteCommit(hash: "a", parents: ["base"], message: "A\n\nFirst body"),
            GitHistoryRewriteCommit(hash: "b", parents: ["a"], message: "B\n\nSecond body"),
            GitHistoryRewriteCommit(hash: "c", parents: ["b"], message: "C")
        ])
        plan.setAction(.edit, for: "a")
        plan.setAction(.squash, for: "b")
        plan.setAction(.fixup, for: "c")
        #expect(plan.steps[1].message == "A\n\nFirst body\n\nB\n\nSecond body")
        // Core must combine the then-current Edit message, not this predicted text.
        #expect(plan.wireSteps[1].message == nil)
        #expect(plan.outputCommitCount == 1)
        plan.setMessage("Custom combined\n\nKeep my full body", for: "b")
        plan.move("b", by: 1)
        plan.setAction(.pick, for: "b")
        plan.setAction(.squash, for: "b")
        #expect(plan.wireSteps.last?.message == "Custom combined\n\nKeep my full body")
        plan.useDefaultSquashMessage(for: "b")
        #expect(plan.wireSteps.last?.message == nil)
        #expect(plan.steps.last?.message == "A\n\nFirst body\n\nB\n\nSecond body")
    }

    @Test
    func defaultSquashPredictionFollowsEarlierRewordsAndIgnoresFixupMessages() {
        var plan = GitRebasePlanDraft(commits: [
            GitHistoryRewriteCommit(hash: "a", parents: ["base"], message: "A"),
            GitHistoryRewriteCommit(hash: "b", parents: ["a"], message: "Discarded fixup message"),
            GitHistoryRewriteCommit(hash: "c", parents: ["b"], message: "C")
        ])
        plan.setAction(.reword, for: "a")
        plan.setAction(.fixup, for: "b")
        plan.setAction(.squash, for: "c")
        plan.setMessage("A revised\n\nComplete body", for: "a")
        #expect(plan.steps.last?.message == "A revised\n\nComplete body\n\nC")
        #expect(plan.wireSteps.last?.message == nil)
        #expect(plan.validationMessage == nil)
        plan.move("b", by: -1)
        #expect(plan.validationMessage != nil)
        plan.move("b", by: 1)
        #expect(plan.validationMessage == nil)
    }

    @Test
    func sharedRebaseRangeExcludesItsBaseAndEditRemainsAnActiveSession() throws {
        struct Fixture: Decodable {
            struct Start: Decodable {
                let expectedState: GitRebaseExpectedState
                let steps: [GitRebaseStep]
            }
            let previewResponse: GitRebasePreview
            let startRequest: Start
            let sessionResponse: GitRebaseSession
            let absentSessionResponse: GitRebaseSession?
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/git/rebase-session-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let preview = fixture.previewResponse
        #expect(!preview.commits.contains { $0.hash == preview.base })
        let expected = try #require(preview.expectedState)
        #expect(expected.operation == "interactiveRebase")
        #expect(expected == fixture.startRequest.expectedState)
        let echoed = try JSONDecoder().decode(GitRebaseExpectedState.self, from: JSONEncoder().encode(expected))
        #expect(echoed == expected)
        #expect(fixture.startRequest.steps.first?.action == .edit)
        #expect(fixture.startRequest.steps.first?.message == nil)
        #expect(fixture.startRequest.steps.last?.message == "Revised title\n\nComplete replacement body\n")
        let session = fixture.sessionResponse
        #expect(session.status == .edit)
        #expect(session.conflictedPaths.isEmpty)
        #expect(session.isActive)
        #expect(session.canContinue && session.canAbort)
        #expect(session.currentMessage == "First change\n\nFull body\n")
        #expect(fixture.absentSessionResponse == nil)
    }
}
