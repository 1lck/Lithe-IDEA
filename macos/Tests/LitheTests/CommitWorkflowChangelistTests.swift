import Foundation
import Testing
import LitheCoreContracts
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
        #expect(notices == ["Selected ChangeList or staged files changed before generation finished"])
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
}

@MainActor
private final class ChangelistCommitGit: CommitWorkflowGit {
    var commitMessageSelectionID = UUID()
    var stagedChangeIDs: Set<String> = ["A/feature.swift"]
    var pendingCommitDraft: (message: String, amend: Bool)?
    var readInput: () async -> CommitMessageInput? = {
        CommitMessageInput(path: "A/feature.swift", changeKind: .modified, diff: "+feature")
    }
    func stagedCommitMessageInput() async -> CommitMessageInput? { await readInput() }
    func commitStagedChanges(message: String, amend: Bool) async -> Bool { false }
    func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool { false }
    func confirmPendingSubmoduleCommit() async -> Bool { false }
}
