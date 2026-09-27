import Foundation

// Decisions: .agents/notes/implemented/feature/2026-09-27-workspace-git-commit-plans.md
extension GitFeatureModel {
    package func dismissWorkspaceCommitResults() {
        guard !isCommitting, pendingSubmoduleCommitPlan == nil else { return }
        workspaceCommitAttempt = nil
        workspaceCommitResults = []
    }

    package var canRetryWorkspaceCommit: Bool {
        guard let attempt = workspaceCommitAttempt else { return false }
        return attempt.plan.orderedRoots.contains { root in
            attempt.results[root]?.committed != true || (attempt.plan.push && attempt.results[root]?.pushed != true)
        }
    }

    package func commitStagedChanges(message: String, amend: Bool) async -> Bool {
        await prepareWorkspaceCommit(message: message, amend: amend, push: false)
    }

    @discardableResult
    package func commitAndPushStagedChanges(message: String, amend: Bool) async -> Bool {
        await prepareWorkspaceCommit(message: message, amend: amend, push: true)
    }

    private func prepareWorkspaceCommit(message: String, amend: Bool, push: Bool) async -> Bool {
        guard !isCommitting, pendingSubmoduleCommitPlan == nil else { return false }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { notify?("Enter a commit message"); return false }
        isCommitting = true
        let generation = workspaceCommitGeneration
        defer { if generation == workspaceCommitGeneration { isCommitting = false } }
        guard let plan = await makeWorkspaceCommitPlan(message: message, amend: amend, push: push,
            includeParentReferences: true, retry: false), generation == workspaceCommitGeneration else { return false }
        workspaceCommitAttempt = nil
        workspaceCommitResults = []
        if !plan.dependencyRelations.isEmpty {
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
            push: reviewed.push, includeParentReferences: reviewed.includeParentReferences, retry: reviewed.isRetry),
            generation == workspaceCommitGeneration, pendingSubmoduleCommitPlan?.id == reviewed.id else { return false }
        guard reviewed.matches(current) else {
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
            includeParentReferences: include, retry: plan.isRetry)
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
        includeParentReferences: Bool, retry: Bool) async -> GitSubmoduleCommitPlan? {
        let generation = workspaceCommitGeneration
        guard !isStagingChanges else { notify?("Wait for staging to finish before reviewing the commit plan."); return nil }
        let roots = availableRepositoryRoots.map(\.standardizedFileURL)
        var states: [URL: GitCommitState] = [:]
        for root in roots {
            guard let state = await service.commitState(at: root) else {
                if generation == workspaceCommitGeneration { notify?("Could not inspect \(root.lastPathComponent). No commit was started.") }
                return nil
            }
            guard generation == workspaceCommitGeneration, !Task.isCancelled else { return nil }
            states[root] = state
        }
        let previous = retry ? workspaceCommitAttempt : nil
        if let previous, previous.results.values.contains(where: {
            previous.plan.orderedRoots.contains($0.root) && (!$0.committed || (push && !$0.pushed)) && states[$0.root] == nil
        }) {
            notify?("A repository with unfinished steps is no longer in this workspace. Restore it before retrying.")
            return nil
        }
        var committed = Set(previous?.results.values.filter(\.committed).map(\.root) ?? [])
        var pendingPush = Set(previous?.results.values.filter { result in
            result.committed && push && (!result.pushed
                || previous?.states[result.root]?.head != states[result.root]?.head
                || previous?.states[result.root]?.branch != states[result.root]?.branch)
        }.map(\.root) ?? [])
        var selected = Set(roots.filter { !committed.contains($0) && !(states[$0]?.stagedPaths.isEmpty ?? true) })
        selected.formUnion(pendingPush)
        let relations = GitRepositoryHierarchy.submoduleRelations(repositoryRoots: roots,
            gitlinkPathsByRoot: states.mapValues { $0.gitlinks.map(\.path) })
        if includeParentReferences {
            // A child may already be committed and pushed while its clean parent
            // failed before its gitlink was staged. Keep that unfinished parent.
            for relation in relations where committed.contains(relation.child)
                && previous?.plan.propagatedRelations.contains(relation) == true
                && previous?.results[relation.parent]?.committed == false {
                selected.insert(relation.parent)
            }
            var changed = true
            while changed {
                changed = false
                for relation in relations where selected.contains(relation.child) && !committed.contains(relation.parent) {
                    changed = selected.insert(relation.parent).inserted || changed
                }
            }
        }
        guard !selected.isEmpty else { notify?("Stage at least one change before committing"); return nil }
        let propagation = relations.filter {
            ((selected.contains($0.child) && !committed.contains($0.child))
                || previous?.plan.propagatedRelations.contains($0) == true)
                && selected.contains($0.parent) && !committed.contains($0.parent)
                && (includeParentReferences || states[$0.parent]?.stagedPaths.contains($0.path) == true)
        }
        var dependencies = propagation
        if push {
            // A selected parent pointer may refer to a child commit created outside
            // this batch. Publish that child without creating another commit.
            for relation in relations where selected.contains(relation.parent)
                && (states[relation.parent]?.stagedPaths.contains(relation.path) == true
                    || previous?.plan.dependencyRelations.contains(relation) == true) {
                guard states[relation.child]?.branch != nil else { continue }
                if !selected.contains(relation.child) {
                    selected.insert(relation.child)
                    committed.insert(relation.child)
                    pendingPush.insert(relation.child)
                }
                if !dependencies.contains(relation) { dependencies.append(relation) }
            }
        }
        return GitSubmoduleCommitPlan(message: message, amend: amend, push: push,
            orderedRoots: GitRepositoryHierarchy.commitOrder(roots.filter { selected.contains($0) }, relations: dependencies),
            propagatedRelations: propagation, dependencyRelations: dependencies, includeParentReferences: includeParentReferences,
            states: states, committedRoots: committed, pendingPushRoots: pendingPush, isRetry: retry)
    }

    private func executeWorkspaceCommit(_ plan: GitSubmoduleCommitPlan, generation: UUID) async -> Bool {
        var attempt = GitWorkspaceCommitAttempt(plan: plan, states: plan.states,
            results: plan.isRetry ? workspaceCommitAttempt?.results ?? [:] : [:])
        for root in plan.orderedRoots {
            if attempt.results[root] == nil { attempt.results[root] = GitRepositoryCommitResult(root: root) }
            if plan.committedRoots.contains(root) { attempt.results[root]?.committed = true }
            if plan.pendingPushRoots.contains(root) { attempt.results[root]?.pushed = false }
        }
        for root in attempt.results.keys where !plan.orderedRoots.contains(root) && attempt.results[root]?.committed != true {
            attempt.results[root]?.detail = "Not included in the updated plan"
        }
        var blocked = Set<URL>()
        var commandFailed = false
        func blockParents(of child: URL) {
            var children = [child]
            while let next = children.popLast() {
                for relation in plan.dependencyRelations where relation.child == next {
                    if blocked.insert(relation.parent).inserted { children.append(relation.parent) }
                }
            }
        }
        @MainActor func publish() {
            workspaceCommitAttempt = attempt
            workspaceCommitResults = attempt.results.values.sorted { $0.root.path < $1.root.path }
        }
        for root in plan.orderedRoots {
            guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
            if blocked.contains(root) {
                attempt.results[root]?.detail = "Waiting for submodule"
                publish()
                continue
            }
            guard let expected = attempt.states[root],
                  let actual = await service.commitState(at: root), actual == expected else {
                guard generation == workspaceCommitGeneration else { return false }
                attempt.results[root]?.detail = "Repository changed; review and retry"
                blockParents(of: root)
                publish()
                continue
            }
            guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
            if attempt.results[root]?.committed != true {
                if !expected.conflictedPaths.isEmpty {
                    attempt.results[root]?.detail = "Resolve conflicts: \(expected.conflictedPaths.joined(separator: ", "))"
                    blockParents(of: root); publish(); continue
                }
                var updates: [GitCommitGitlink] = []
                var childChanged = false
                for relation in plan.propagatedRelations where relation.parent == root {
                    guard let child = await service.commitState(at: relation.child),
                          child.head == attempt.states[relation.child]?.head, let head = child.head,
                          attempt.results[relation.child]?.committed == true else {
                        childChanged = true
                        break
                    }
                    updates.append(GitCommitGitlink(path: relation.path, revision: head))
                }
                guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
                if childChanged {
                    attempt.results[root]?.detail = "Submodule changed; review and retry"
                    blockParents(of: root); publish(); continue
                }
                let markers = await service.conflictMarkerPaths(at: root)
                guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
                if !markers.isEmpty {
                    attempt.results[root]?.detail = "Resolve conflict markers: \(markers.joined(separator: ", "))"
                    blockParents(of: root); publish(); continue
                }
                // Each repository receives a fresh execution context. Stopping one
                // command blocks its dependents but leaves independent roots runnable.
                let result = await withGitOperation {
                    await service.commit(at: root, message: plan.message,
                        amend: plan.amend && !expected.stagedPaths.isEmpty,
                        expected: expected, gitlinkUpdates: updates)
                }
                guard generation == workspaceCommitGeneration else { return false }
                let postCommitState = await service.commitState(at: root)
                guard generation == workspaceCommitGeneration else { return false }
                // A hook or cancellation can report failure after HEAD advanced.
                // Preserve that step rather than creating a second commit on retry.
                let headAdvanced = postCommitState?.head != nil && postCommitState?.head != expected.head
                if result.succeeded || headAdvanced {
                    attempt.results[root]?.committed = true
                    attempt.results[root]?.detail = plan.push ? "Committed; push pending" : "Committed"
                }
                if !result.succeeded {
                    commandFailed = true
                    attempt.results[root]?.detail = headAdvanced
                        ? "HEAD advanced; review before continuing. \(trimmedMessage(result))" : trimmedMessage(result)
                    blockParents(of: root)
                }
                // Preserve post-command state, including gitlinks restaged before a
                // hook failure, so retry never repeats a successful child commit.
                attempt.states[root] = postCommitState
                guard generation == workspaceCommitGeneration else { return false }
                publish()
                if !result.succeeded { continue }
            }
            if plan.push && attempt.results[root]?.pushed != true {
                guard let expected = attempt.states[root],
                      await service.commitState(at: root) == expected,
                      let reference = await service.references(at: root, operationID: "commit-push-reference-\(UUID().uuidString)")?.references.first(where: \.isCurrent),
                      reference.fullName == expected.branch else {
                    guard generation == workspaceCommitGeneration else { return false }
                    attempt.results[root]?.detail = "Committed; branch changed or detached. Review and retry push."
                    blockParents(of: root); publish(); continue
                }
                guard generation == workspaceCommitGeneration, !Task.isCancelled else { return false }
                let result = await withGitOperation { await service.pushWorkspaceCommit(reference, at: root, expected: expected) }
                guard generation == workspaceCommitGeneration else { return false }
                attempt.results[root]?.pushed = result.succeeded
                attempt.results[root]?.detail = result.succeeded ? "Committed and pushed" : "Committed; push failed: \(trimmedMessage(result))"
                if !result.succeeded { blockParents(of: root) }
                publish()
            }
        }
        guard generation == workspaceCommitGeneration else { return false }
        publish()
        await refreshGit()
        guard generation == workspaceCommitGeneration else { return false }
        let succeeded = !commandFailed && plan.orderedRoots.allSatisfy { root in
            attempt.results[root]?.committed == true && (!plan.push || attempt.results[root]?.pushed == true)
        }
        notify?(succeeded ? (plan.push ? "Committed and pushed all selected repositories" : "Committed changes")
            : "Some repositories need attention. Completed steps are saved; retry to continue.")
        return succeeded
    }
}
