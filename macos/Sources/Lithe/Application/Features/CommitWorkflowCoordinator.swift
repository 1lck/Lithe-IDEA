import Foundation
import LitheCoreContracts

/// The Git operations needed by the application-owned commit workflow.
@MainActor
protocol CommitWorkflowGit: AnyObject {
    var stagedChangeIDs: Set<String> { get }
    func stagedCommitMessageInput() async -> CommitMessageInput?
    func commitStagedChanges(message: String, amend: Bool) async -> Bool
    func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool
}

/// Coordinates submission and AI generation without owning Git or AI services.
@MainActor
final class CommitWorkflowCoordinator {
    private let draft: CommitDraftFeatureModel
    private let activateGit: () async -> (any CommitWorkflowGit)?
    private let workspaceGeneration: () -> Int
    private let generate: (CommitMessageInput) async throws -> String
    private let notify: (String) -> Void
    private var isSubmitting = false

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
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let generation = workspaceGeneration()
        let message = draft.message
        let amend = draft.amend
        guard let git = await activateGit(),
              generation == workspaceGeneration(), !Task.isCancelled else { return }
        let succeeded = if push {
            await git.commitAndPushStagedChanges(message: message, amend: amend)
        } else {
            await git.commitStagedChanges(message: message, amend: amend)
        }
        guard succeeded, generation == workspaceGeneration() else { return }
        // Preserve edits made while Git was running, even after a successful commit.
        if draft.message == message && draft.amend == amend {
            draft.clearAfterCommit()
        }
    }

    func generateMessage() async {
        let generation = workspaceGeneration()
        do {
            let outcome = try await draft.generate {
                guard let git = await activateGit(),
                      generation == workspaceGeneration(), !Task.isCancelled else { return nil }
                let stagedIDs = git.stagedChangeIDs
                guard !stagedIDs.isEmpty else {
                    notify("Stage at least one file first")
                    return nil
                }
                let input = await git.stagedCommitMessageInput()
                guard generation == workspaceGeneration(), !Task.isCancelled else { return nil }
                guard let input else { throw CommitMessageGenerationError.emptyDiff }
                let message = try await generate(input)
                guard generation == workspaceGeneration(), !Task.isCancelled else { return nil }
                guard git.stagedChangeIDs == stagedIDs else {
                    notify("Staged files changed before generation finished")
                    return nil
                }
                return message
            }
            if outcome == .filledDraft { notify("Commit message generated") }
        } catch {
            guard generation == workspaceGeneration(), !Task.isCancelled else { return }
            notify(error.localizedDescription)
        }
    }

    func applyGeneratedMessage() {
        guard draft.applyGeneratedMessage() else { return }
        notify("Commit message replaced")
    }
}
