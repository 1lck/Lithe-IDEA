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
        guard !isCommitting, !isWorktreeCommitBlocked, pendingSubmoduleCommitPlan == nil,
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
        // A push always shows where each branch goes and waits for the user, even
        // when the repositories themselves need no review.
        if plan.preparation.requiresConfirmation || push {
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
            push: reviewed.push, includeParentReferences: reviewed.includeParentReferences, retry: reviewed.isRetry, reviewed: reviewed.core,
            pushTargets: reviewed.core.pushTargets, previousChoices: reviewed.pushChoices),
            generation == workspaceCommitGeneration, pendingSubmoduleCommitPlan?.id == reviewed.id else { return false }
        // Core refuses to step a repository whose destination is unanswered, but the
        // dialog must not get that far: the user still has to see the question.
        guard !current.needsPushTargetChoice else {
            pendingSubmoduleCommitPlan = current
            notify?("Choose which branch to update before pushing.")
            return false
        }
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
            includeParentReferences: include, retry: plan.isRetry, reviewed: plan.core,
            pushTargets: plan.core.pushTargets, previousChoices: plan.pushChoices)
        guard generation == workspaceCommitGeneration, pendingSubmoduleCommitPlan?.id == plan.id else { return }
        pendingSubmoduleCommitPlan = replacement
    }

    /// Records which branch a differently named upstream should update. Core checks the
    /// answer against the repository again before pushing, so the plan is rebuilt to
    /// carry it and to ask again if the tracking configuration has moved since.
    package func choosePushTarget(_ choice: GitPushTargetChoice, for question: GitWorkspacePushTargetQuestion) async {
        guard !isCommitting, let plan = pendingSubmoduleCommitPlan else { return }
        var targets = plan.core.pushTargets ?? [:]
        targets[question.repositoryId] = question.confirmation(for: choice)
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        let replacement = await makeWorkspaceCommitPlan(message: plan.message, amend: plan.amend, push: plan.push,
            includeParentReferences: plan.includeParentReferences, retry: plan.isRetry, reviewed: plan.core,
            pushTargets: targets, previousChoices: plan.pushChoices)
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
        includeParentReferences: Bool, retry: Bool, reviewed: GitWorkspaceCommitPlan? = nil,
        pushTargets: [String: GitWorkspaceConfirmedPushTarget]? = nil,
        previousChoices: [String: GitWorkspacePushTargetQuestion] = [:]) async -> GitSubmoduleCommitPlan? {
        guard !isStagingChanges, !isWorktreeCommitBlocked else { notify?("Wait for staging to finish before reviewing the commit plan."); return nil }
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
            previous: retry ? workspaceCommitAttempt : nil, reviewed: reviewed, pathScope: scope,
            pushTargets: pushTargets)
        let response = await withGitOperation { await service.prepareWorkspaceCommit(request) }
        guard generation == workspaceCommitGeneration, !Task.isCancelled else { return nil }
        switch response {
        case .success(let preparation):
            var plan = GitSubmoduleCommitPlan(preparation: preparation)
            guard push else { return plan }
            // A choice stays changeable only while Core still holds its answer; a
            // question Core raised again replaces the stale one.
            let answered = preparation.session.plan.pushTargets ?? [:]
            plan.pushChoices = previousChoices.filter { answered[$0.key] != nil }
            for question in preparation.pushTargetQuestions { plan.pushChoices[question.repositoryId] = question }
            plan.pushDestinations = await resolvePushDestinations(for: plan)
            guard generation == workspaceCommitGeneration, !Task.isCancelled else { return nil }
            return plan
        case .failure(let error): notify?(error.message); return nil
        }
    }

    /// Core's resolution of where each pushing branch goes. A repository whose upstream
    /// has a different name is answered by the user instead, and one that cannot
    /// resolve a destination (no remote, detached HEAD) is left to the push step, which
    /// reports Git's own reason.
    private func resolvePushDestinations(for plan: GitSubmoduleCommitPlan) async -> [URL: GitPushPreview] {
        var destinations: [URL: GitPushPreview] = [:]
        for binding in plan.core.repositories where plan.core.orderedIds.contains(binding.id) {
            guard plan.pushChoices[binding.id] == nil, let branch = plan.core.states[binding.id]?.branch else { continue }
            let root = URL(fileURLWithPath: binding.root).standardizedFileURL
            // Core reports the checked-out branch as its full reference name.
            let prefix = "refs/heads/"
            let shortName = branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
            let reference = GitReference(fullName: prefix + shortName, shortName: shortName, kind: .local,
                isCurrent: true, upstreamShortName: nil)
            if case .success(let preview) = await service.pushPreview(reference, pushTarget: nil, at: root) {
                destinations[root] = preview
            }
        }
        return destinations
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
