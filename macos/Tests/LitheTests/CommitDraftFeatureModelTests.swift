import Testing
@testable import Lithe

@Suite("Commit draft")
@MainActor
struct CommitDraftFeatureModelTests {
    @Test(arguments: ["", " \n "])
    func generationFillsAnEmptyDraft(_ initial: String) async throws {
        let draft = CommitDraftFeatureModel()
        draft.message = initial
        let outcome = try await draft.generate { "Generated message" }
        #expect(outcome == .filledDraft)
        #expect(draft.message == "Generated message")
        #expect(draft.pendingGeneratedMessage == nil)
        #expect(!draft.isGenerating)
    }

    @Test
    func generationPreservesEditsMadeWhileItRunsUntilConfirmation() async throws {
        let draft = CommitDraftFeatureModel()
        let outcome = try await draft.generate {
            #expect(draft.isGenerating)
            draft.message = "User draft"
            return "Generated message"
        }
        #expect(outcome == .awaitingConfirmation)
        #expect(draft.message == "User draft")
        #expect(draft.pendingGeneratedMessage == "Generated message")
        #expect(draft.applyGeneratedMessage())
        #expect(draft.message == "Generated message")
        #expect(draft.pendingGeneratedMessage == nil)
        #expect(!draft.applyGeneratedMessage())
    }

    @Test
    func discardAndCommitSuccessHaveSeparateDraftTransitions() async throws {
        let draft = CommitDraftFeatureModel()
        draft.message = "User draft"
        draft.amend = true
        _ = try await draft.generate { "Replacement" }
        draft.discardGeneratedMessage()
        #expect(draft.message == "User draft")
        #expect(draft.amend)
        #expect(draft.pendingGeneratedMessage == nil)
        draft.clearAfterCommit()
        #expect(draft.message.isEmpty)
        #expect(!draft.amend)
    }

    @Test
    func generationRejectsAnOverlappingRequestAndRestoresIdleAfterFailure() async throws {
        let draft = CommitDraftFeatureModel()
        let outcome = try await draft.generate {
            let overlap = try await draft.generate {
                Issue.record("Overlapping generation must not run")
                return "Unexpected"
            }
            #expect(overlap == nil)
            return nil
        }
        #expect(outcome == nil)
        #expect(!draft.isGenerating)
        do {
            _ = try await draft.generate { throw Failure.expected }
            Issue.record("Expected generation failure")
        } catch {
            #expect(error as? Failure == .expected)
        }
        #expect(!draft.isGenerating)
        #expect(draft.message.isEmpty)
    }

    private enum Failure: Error { case expected }
}
