import Foundation
@testable import LitheGitModule
import Testing

struct GitInteractiveRebaseTests {
    private struct PlanFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let steps: [GitRebaseStep]
            let response: GitRebasePlanPreview
        }
        struct Commit: Decodable { let hash: String; let message: String }
        let commits: [Commit]
        let cases: [Case]
        var rewriteCommits: [GitHistoryRewriteCommit] {
            commits.map { GitHistoryRewriteCommit(hash: $0.hash, parents: [], message: $0.message) }
        }
    }

    private func planFixture() throws -> PlanFixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/git/rebase-plan-preview-v1.json"))
        return try JSONDecoder().decode(PlanFixture.self, from: data)
    }

    @Test
    func draftSendsOnlyExplicitOverridesAndShowsCoreDerivedMessages() throws {
        let fixture = try planFixture()
        let sample = try #require(fixture.cases.first)
        var plan = GitRebasePlanDraft(commits: fixture.rewriteCommits)
        for step in sample.steps { plan.setAction(step.action, for: step.hash) }
        // The shared fixture owns the derivation; Core must receive no predicted text.
        let request = plan.previewRequest
        #expect(request.steps.map(\.hash) == sample.steps.map(\.hash))
        #expect(request.steps.allSatisfy { $0.message == nil })
        #expect(!plan.isPlanned && plan.wireSteps.isEmpty)
        plan.apply(sample.response, for: request)
        #expect(plan.isPlanned)
        #expect(plan.wireSteps == sample.response.startSteps)
        #expect(plan.outputCommitCount == sample.response.outputCommitCount)
        for row in sample.response.steps {
            #expect(plan.steps.first { $0.hash == row.hash }?.message == row.message)
        }
    }

    @Test
    func editingTheDraftInvalidatesCoreAnswersAndIgnoresStaleOnes() throws {
        let fixture = try planFixture()
        let sample = try #require(fixture.cases.first)
        var plan = GitRebasePlanDraft(commits: fixture.rewriteCommits)
        for step in sample.steps { plan.setAction(step.action, for: step.hash) }
        let stale = plan.previewRequest
        let squash = try #require(sample.steps.first { $0.action == .squash })
        plan.setMessage("Custom combined", for: squash.hash)
        #expect(!plan.isPlanned)
        #expect(plan.previewRequest.steps.first { $0.hash == squash.hash }?.message == "Custom combined")
        plan.apply(sample.response, for: stale)
        #expect(!plan.isPlanned && plan.wireSteps.isEmpty)
        plan.useDefaultSquashMessage(for: squash.hash)
        #expect(plan.previewRequest == stale)
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
