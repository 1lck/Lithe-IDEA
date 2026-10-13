import Foundation

// Decisions: .agents/notes/implemented/feature/2026-09-27-workspace-git-commit-plans.md
extension GitFeatureModel {
    package func dismissWorkspaceCommitResults() {
        guard !isCommitting, pendingSubmoduleCommitPlan == nil else { return }
        workspaceCommitAttempt = nil
        workspaceCommitResults = []
    }

    package var canRetryWorkspaceCommit: Bool {
        workspaceCommitAttempt?.canRetry == true
    }

    package func commitStagedChanges(message: String, amend: Bool) async -> Bool {
        await prepareWorkspaceCommit(message: message, amend: amend, push: false)
    }

    @discardableResult
    package func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool {
        await prepareWorkspaceCommit(message: message, amend: amend, push: true)
    }

    private func prepareWorkspaceCommit(message: String, amend: Bool, push: Bool) async -> Bool {
        loadChangelistsIfNeeded()
        guard !isCommitting, pendingSubmoduleCommitPlan == nil,
              workspaceCommitAttempt == nil || workspaceCommitAttempt?.succeeded == true else { return false }
        if let error = changelistCommitError { notify?(error); return false }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { notify?("Enter a commit message"); return false }
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        guard let plan = await makeWorkspaceCommitPlan(message: message, amend: amend, push: push,
            includeParentReferences: includeChangelistParentReferences, retry: false), generation == workspaceCommitGeneration else { return false }
        workspaceCommitAttempt = nil
        workspaceCommitResults = []
        if plan.preparation.requiresConfirmation {
            pendingSubmoduleCommitPlan = plan
            return false
        }
        return await executeWorkspaceCommit(plan, generation: generation)
    }

    package func cancelPendingSubmoduleCommit() { pendingSubmoduleCommitPlan = nil }

    /// Rebuild even when a dialog is already visible: confirmation authorizes
    /// this exact plan, never a new selection silently substituted for it.
    @discardableResult
    package func confirmPendingSubmoduleCommit() async -> Bool {
        guard !isCommitting, let reviewed = pendingSubmoduleCommitPlan else { return false }
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        guard let current = await makeWorkspaceCommitPlan(message: reviewed.message, amend: reviewed.amend,
            push: reviewed.push, includeParentReferences: reviewed.includeParentReferences, retry: reviewed.isRetry, reviewed: reviewed.core),
            generation == workspaceCommitGeneration, pendingSubmoduleCommitPlan?.id == reviewed.id else { return false }
        guard !current.preparation.reviewChanged else {
            pendingSubmoduleCommitPlan = current
            notify?("The commit plan changed. Review the updated repositories and references before continuing.")
            return false
        }
        pendingSubmoduleCommitPlan = nil
        return await executeWorkspaceCommit(current, generation: generation)
    }

    package func setCommitPlanParentReferences(_ include: Bool) async {
        guard !isCommitting, let plan = pendingSubmoduleCommitPlan else { return }
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        let replacement = await makeWorkspaceCommitPlan(message: plan.message, amend: plan.amend, push: plan.push,
            includeParentReferences: include, retry: plan.isRetry, reviewed: plan.core)
        guard generation == workspaceCommitGeneration, pendingSubmoduleCommitPlan?.id == plan.id else { return }
        pendingSubmoduleCommitPlan = replacement
    }

    /// Retry is explicit and always reviewable, including when only a push remains.
    package func prepareWorkspaceCommitRetry() async {
        guard !isCommitting, pendingSubmoduleCommitPlan == nil, let attempt = workspaceCommitAttempt else { return }
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        let plan = await makeWorkspaceCommitPlan(message: attempt.plan.message, amend: attempt.plan.amend,
            push: attempt.plan.push, includeParentReferences: attempt.plan.includeParentReferences, retry: true)
        guard generation == workspaceCommitGeneration else { return }
        pendingSubmoduleCommitPlan = plan
    }

    private func makeWorkspaceCommitPlan(message: String, amend: Bool, push: Bool,
        includeParentReferences: Bool, retry: Bool, reviewed: GitWorkspaceCommitPlan? = nil) async -> GitSubmoduleCommitPlan? {
        guard !isStagingChanges else { notify?("Wait for staging to finish before reviewing the commit plan."); return nil }
        guard let workspace = workspaceURLProvider?() else { return nil }
        let generation = workspaceCommitGeneration
        let base = workspace.standardizedFileURL.pathComponents
        let bindings = availableRepositoryRoots.map { root in
            let components = root.standardizedFileURL.pathComponents
            let shared = zip(base, components).prefix { $0 == $1 }.count
            let relative = Array(repeating: "..", count: base.count - shared) + Array(components.dropFirst(shared))
            return GitWorkspaceRepositoryBinding(id: relative.isEmpty ? "." : relative.joined(separator: "/"),
                root: root.standardizedFileURL.path)
        }
        // Preserve the reviewed/retry scope even if status refreshes report new paths.
        let scope = retry ? workspaceCommitAttempt?.plan.pathScope
            : reviewed?.pathScope ?? changelists.commitScope(repositories: bindings, changes: gitChanges)
        let request = GitWorkspaceCommitRequest(repositories: bindings,
            message: message, amend: amend, push: push, includeParentReferences: includeParentReferences,
            previous: retry ? workspaceCommitAttempt : nil, reviewed: reviewed, pathScope: scope)
        let response = await withGitOperation { await service.prepareWorkspaceCommit(request) }
        guard generation == workspaceCommitGeneration, !Task.isCancelled else { return nil }
        switch response {
        case .success(let preparation): return GitSubmoduleCommitPlan(preparation: preparation)
        case .failure(let error): notify?(error.message); return nil
        }
    }

    private func executeWorkspaceCommit(_ plan: GitSubmoduleCommitPlan, generation: UUID) async -> Bool {
        var session = plan.preparation.session
        workspaceCommitAttempt = session
        workspaceCommitResults = session.displayedResults
        while !session.finished {
            guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
            // Core chooses the repository and operation. Native code only owns
            // execution UI, authentication, cancellation and workspace lifetime.
            let current = session
            let response = await withGitOperation { await service.stepWorkspaceCommit(current) }
            guard generation == workspaceCommitGeneration else { return false }
            switch response {
            case .success(let next): session = next
            case .failure(let error): notify?(error.message); return false
            }
            workspaceCommitAttempt = session
            workspaceCommitResults = session.displayedResults
        }
        await refreshGit()
        guard generation == workspaceCommitGeneration else { return false }
        notify?(session.succeeded ? (plan.push ? "Committed and pushed all selected repositories" : "Committed changes")
            : "Some repositories need attention. Completed steps are saved; retry to continue.")
        return session.succeeded
    }
}
