import Foundation
import LitheCoreContracts
import LitheGitModule

/// The Git operations needed by the application-owned commit workflow.
@MainActor
protocol CommitWorkflowGit: AnyObject {
    /// Active ChangeList selection, including changes that return to the original list.
    var commitMessageSelectionID: UUID { get }
    /// Staged changes in that list, across the workspace repositories.
    var stagedChangeIDs: Set<String> { get }
    var pendingCommitDraft: (message: String, amend: Bool)? { get }
    func stagedCommitMessageContext() async throws -> GitCommitMessageContext
    func isCommitMessageContextCurrent(_ context: GitCommitMessageContext) async -> Bool
    /// Commits each repository's staged changes independently while sharing the
    /// commit message. The Git feature owns repository grouping and failure
    /// reporting so the coordinator remains unaware of Git's storage model.
    func commitStagedChanges(message: String, amend: Bool) async -> Bool
    func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool
    func confirmPendingSubmoduleCommit() async -> Bool
}

/// Coordinates submission and AI generation without owning Git or AI services.
@MainActor
final class CommitWorkflowCoordinator {
    private let draft: CommitDraftFeatureModel
    private let activateGit: () async -> (any CommitWorkflowGit)?
    private let workspaceGeneration: () -> Int
    private let generate: (CommitMessageInput) async throws -> String
    private let notify: (String) -> Void
    var notifyFailure: ((String) -> Void)?
    private var isSubmitting = false
    private struct PendingProof {
        let git: any CommitWorkflowGit
        let context: GitCommitMessageContext
        let workspace: Int
        let selection: UUID
        let stagedIDs: Set<String>
    }
    private var pendingProof: PendingProof?
    private var generationID = UUID()


    init(
        draft: CommitDraftFeatureModel,
        activateGit: @escaping () async -> (any CommitWorkflowGit)?,
        workspaceGeneration: @escaping () -> Int,
        generate: @escaping (CommitMessageInput) async throws -> String,
        notify: @escaping (String) -> Void
    ) {
        self.draft = draft
        self.activateGit = activateGit
        self.workspaceGeneration = workspaceGeneration
        self.generate = generate
        self.notify = notify
    }

    func commit(push: Bool = false) async {
        await submitCommit(push: push, confirmSubmodulePlan: false)
    }

    func confirmPendingSubmoduleCommit() async {
        await submitCommit(push: false, confirmSubmodulePlan: true)
    }

    private func submitCommit(push: Bool, confirmSubmodulePlan: Bool) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let generation = workspaceGeneration()
        let message = draft.message
        let amend = draft.amend
        guard let git = await activateGit(),
              generation == workspaceGeneration(), !Task.isCancelled else { return }
        let submittedMessage = confirmSubmodulePlan ? git.pendingCommitDraft?.message ?? message : message
        let submittedAmend = confirmSubmodulePlan ? git.pendingCommitDraft?.amend ?? amend : amend
        let succeeded: Bool
        if confirmSubmodulePlan {
            succeeded = await git.confirmPendingSubmoduleCommit()
        } else if push {
            succeeded = await git.commitAndPushStagedChanges(message: message, amend: amend)
        } else {
            succeeded = await git.commitStagedChanges(message: message, amend: amend)
        }
        guard succeeded, generation == workspaceGeneration() else { return }
        // Preserve edits made while Git was running, even after a successful commit.
        if draft.message.trimmingCharacters(in: .whitespacesAndNewlines) == submittedMessage.trimmingCharacters(in: .whitespacesAndNewlines) && draft.amend == submittedAmend {
            draft.clearAfterCommit()
        }
    }

    func generateMessage() async {
        guard !draft.isGenerating else { return }
        let generation = workspaceGeneration()
        let operation = UUID()
        generationID = operation
        pendingProof = nil
        var proof: PendingProof?
        do {
            let outcome = try await draft.generate {
                guard let git = await activateGit(),
                      generation == workspaceGeneration(), !Task.isCancelled else { return nil }
                let selectionID = git.commitMessageSelectionID
                let stagedIDs = git.stagedChangeIDs
                guard !stagedIDs.isEmpty else {
                    notify("Stage at least one file first")
                    return nil
                }
                let context = try await git.stagedCommitMessageContext()
                guard generation == workspaceGeneration(), generationID == operation, !Task.isCancelled else { return nil }
                guard git.commitMessageSelectionID == selectionID, git.stagedChangeIDs == stagedIDs else {
                    throw CommitMessageGenerationError.staleChanges
                }
                let message = try await generate(context.input)
                guard generation == workspaceGeneration(), generationID == operation, !Task.isCancelled else { return nil }
                guard git.commitMessageSelectionID == selectionID, git.stagedChangeIDs == stagedIDs,
                      await git.isCommitMessageContextCurrent(context),
                      generation == workspaceGeneration(), generationID == operation, !Task.isCancelled,
                      git.commitMessageSelectionID == selectionID, git.stagedChangeIDs == stagedIDs else {
                    throw CommitMessageGenerationError.staleChanges
                }
                proof = PendingProof(git: git, context: context, workspace: generation,
                    selection: selectionID, stagedIDs: stagedIDs)
                pendingProof = proof
                return message
            }
            guard generationID == operation else { return }
            if outcome != .awaitingConfirmation { pendingProof = nil }
            if outcome == .filledDraft { notify("Commit message generated") }
        } catch {
            guard generation == workspaceGeneration(), generationID == operation, !Task.isCancelled else { return }
            (notifyFailure ?? notify)(error.localizedDescription)
        }
    }

    func discardGeneratedMessage() {
        pendingProof = nil
        draft.discardGeneratedMessage()
    }

    /// Capture the pending text synchronously before the confirmation dialog
    /// dismisses, then recheck Git and the user's draft immediately before use.
    @discardableResult
    func applyGeneratedMessage() -> Task<Void, Never>? {
        guard let message = draft.pendingGeneratedMessage, let proof = pendingProof else { return nil }
        let previousDraft = draft.message
        let operation = generationID
        draft.discardGeneratedMessage()
        pendingProof = nil
        return Task { [weak self] in
            guard let self, operation == self.generationID,
                  proof.workspace == self.workspaceGeneration(),
                  proof.git.commitMessageSelectionID == proof.selection,
                  proof.git.stagedChangeIDs == proof.stagedIDs,
                  await proof.git.isCommitMessageContextCurrent(proof.context),
                  operation == self.generationID, !Task.isCancelled,
                  proof.workspace == self.workspaceGeneration(),
                  proof.git.commitMessageSelectionID == proof.selection,
                  proof.git.stagedChangeIDs == proof.stagedIDs else {
                if let self, operation == self.generationID, proof.workspace == self.workspaceGeneration() {
                    (self.notifyFailure ?? self.notify)(CommitMessageGenerationError.staleChanges.localizedDescription)
                }
                return
            }
            guard self.draft.message == previousDraft else {
                (self.notifyFailure ?? self.notify)(CommitMessageGenerationError.draftChanged.localizedDescription)
                return
            }
            self.draft.message = message
            self.notify("Commit message replaced")
        }
    }

}
