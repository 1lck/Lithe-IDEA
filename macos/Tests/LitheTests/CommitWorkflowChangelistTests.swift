import Foundation
import Testing
import LitheCoreContracts
import LitheGitModule
@testable import Lithe

@MainActor
struct CommitWorkflowChangelistTests {
    @Test(arguments: [false, true])
    func staleGenerationCannotFillTheDraftOrOfferAReplacement(_ changeIdentityOnly: Bool) async {
        let draft = CommitDraftFeatureModel()
        let git = ChangelistCommitGit()
        let entered = TestGate()
        let release = TestGate()
        let finished = TestGate()
        var notices: [String] = []
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in
                entered.open()
                #expect(await release.waitUntilOpen())
                return "Message for A"
            }, notify: { notices.append($0) })
        let task = Task { await coordinator.generateMessage(); finished.open() }
        defer { entered.open(); release.open(); finished.open(); task.cancel() }
        #expect(await entered.waitUntilOpen())
        // The global index can stay unchanged when the list or its membership changes.
        if changeIdentityOnly { git.commitMessageSelectionID = UUID() }
        else { git.stagedChangeIDs = ["B/feature.swift"] }
        draft.message = "User draft for B"
        release.open()
        #expect(await finished.waitUntilOpen())
        await task.value
        #expect(draft.message == "User draft for B")
        #expect(draft.pendingGeneratedMessage == nil)
        #expect(!draft.isGenerating)
        #expect(notices == [CommitMessageGenerationError.staleChanges.localizedDescription])
    }

    @Test
    func selectionChangesWhileReadingDiffsDoNotStartAI() async {
        let draft = CommitDraftFeatureModel()
        let git = ChangelistCommitGit()
        let entered = TestGate()
        let release = TestGate()
        let finished = TestGate()
        git.readInput = {
            entered.open()
            #expect(await release.waitUntilOpen())
            return CommitMessageInput(path: "A/feature.swift", changeKind: .modified, diff: "+feature")
        }
        var requests = 0
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in requests += 1; return "Old message" }, notify: { _ in })
        let task = Task { await coordinator.generateMessage(); finished.open() }
        defer { entered.open(); release.open(); finished.open(); task.cancel() }
        #expect(await entered.waitUntilOpen())
        git.commitMessageSelectionID = UUID()
        release.open()
        #expect(await finished.waitUntilOpen())
        await task.value
        #expect(requests == 0)
        #expect(draft.message.isEmpty)
        #expect(draft.pendingGeneratedMessage == nil)
    }

    @Test
    func unchangedSelectionStillReceivesItsGeneratedMessage() async {
        let draft = CommitDraftFeatureModel()
        let git = ChangelistCommitGit()
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { input in
                #expect(input.files.map(\.path) == ["A/feature.swift"])
                return "Current message"
            }, notify: { _ in })
        await coordinator.generateMessage()
        #expect(draft.message == "Current message")
        #expect(!draft.isGenerating)
    }
    @Test
    func samePathsWithNewContentCannotApplyAStaleGeneration() async {
        let draft = CommitDraftFeatureModel()
        let git = ChangelistCommitGit()
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in git.contextCurrent = false; return "Old message" }, notify: { _ in })
        await coordinator.generateMessage()
        #expect(draft.message.isEmpty && draft.pendingGeneratedMessage == nil)
    }

    @Test
    func confirmedUnchangedContextReplacesTheDraft() async {
        let draft = CommitDraftFeatureModel()
        draft.message = "Original"
        let git = ChangelistCommitGit()
        var notices: [String] = []
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in "Generated" }, notify: { notices.append($0) })
        await coordinator.generateMessage()
        #expect(draft.pendingGeneratedMessage == "Generated")
        await coordinator.applyGeneratedMessage()?.value
        #expect(draft.message == "Generated")
        #expect(notices == ["Commit message replaced"])
    }

    @Test
    func confirmationRechecksGitAndKeepsTheExistingDraft() async {
        let draft = CommitDraftFeatureModel()
        draft.message = "User draft"
        let git = ChangelistCommitGit()
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in "Old message" }, notify: { _ in })
        await coordinator.generateMessage()
        #expect(draft.pendingGeneratedMessage == "Old message")
        git.contextCurrent = false
        await coordinator.applyGeneratedMessage()?.value
        #expect(draft.message == "User draft")
        #expect(draft.pendingGeneratedMessage == nil)
    }

    @Test
    func typingDuringConfirmationRecheckDoesNotGetOverwritten() async {
        let draft = CommitDraftFeatureModel()
        draft.message = "Before confirmation"
        let git = ChangelistCommitGit()
        let entered = TestGate(), release = TestGate()
        let coordinator = CommitWorkflowCoordinator(draft: draft, activateGit: { git }, workspaceGeneration: { 0 },
            generate: { _ in "Generated" }, notify: { _ in })
        await coordinator.generateMessage()
        git.verify = { entered.open(); return await release.waitUntilOpen() }
        let task = coordinator.applyGeneratedMessage()
        defer { release.open(); task?.cancel() }
        #expect(await entered.waitUntilOpen())
        draft.message = "Typed while checking"
        release.open()
        await task?.value
        #expect(draft.message == "Typed while checking")
    }

}

@MainActor
private final class ChangelistCommitGit: CommitWorkflowGit {
    var commitMessageSelectionID = UUID()
    var stagedChangeIDs: Set<String> = ["A/feature.swift"]
    var pendingCommitDraft: (message: String, amend: Bool)?
    var readInput: () async -> CommitMessageInput? = {
        CommitMessageInput(path: "A/feature.swift", changeKind: .modified, diff: "+feature")
    }
    var contextCurrent = true
    var verify: (() async -> Bool)?
    func stagedCommitMessageContext() async throws -> GitCommitMessageContext {
        guard let input = await readInput() else { throw CommitMessageGenerationError.emptyDiff }
        return GitCommitMessageContext(input: input, token: "state", repositories: [])
    }
    func isCommitMessageContextCurrent(_ context: GitCommitMessageContext) async -> Bool {
        if let verify { return await verify() }
        return contextCurrent
    }
    func commitStagedChanges(message: String, amend: Bool) async -> Bool { false }
    func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool { false }
    func confirmPendingSubmoduleCommit() async -> Bool { false }
}
