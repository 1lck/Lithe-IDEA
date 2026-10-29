import Foundation
import LitheGitModule

/// Retains each checkout's editor when switching worktrees or detail tabs.
@MainActor
final class WorktreeCommitSession {
    let feature: GitFeatureModel
    let draft: CommitDraftFeatureModel
    let workflow: CommitWorkflowCoordinator

    init(feature: GitFeatureModel, draft: CommitDraftFeatureModel, workflow: CommitWorkflowCoordinator) {
        self.feature = feature
        self.draft = draft
        self.workflow = workflow
    }
}

@MainActor
final class WorktreeCommitSessions {
    private var generation: Int?
    private var sessions: [URL: WorktreeCommitSession] = [:]

    func session(for feature: GitFeatureModel, generation: Int,
                 make: () -> WorktreeCommitSession) -> WorktreeCommitSession {
        if self.generation != generation {
            sessions = [:]
            self.generation = generation
        }
        guard let root = feature.gitRepositoryRoot else { return make() }
        if let existing = sessions[root], existing.feature === feature { return existing }
        let session = make()
        sessions[root] = session
        return session
    }
}
