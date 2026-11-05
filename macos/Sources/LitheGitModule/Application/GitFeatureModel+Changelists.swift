import Foundation
import LitheModuleAPI

extension GitFeatureModel {
    package var changelistEditingDisabled: Bool {
        isCommitting || isWorktreeCommitBlocked || isStagingChanges || pendingSubmoduleCommitPlan != nil
            || (workspaceCommitAttempt != nil && workspaceCommitAttempt?.succeeded != true)
            || changelistStorageFailed || changelistProjectionPending
    }

    package var activeChangelistChanges: [GitChange] {
        guard !changelistStorageFailed, !changelistProjectionPending else { return [] }
        return gitChanges.filter { changelists.listID(for: $0) == changelists.activeID }
    }

    package var changelistCommitError: String? {
        if changelistStorageFailed { return "ChangeList storage is unavailable. Restore the saved data and reopen the workspace." }
        if changelistProjectionPending { return nil }
        if gitChanges.contains(where: { $0.isStaged && changelists.listID(for: $0) != changelists.activeID }) {
            return "Other ChangeLists have staged files. Unstage them before committing the current ChangeList."
        }
        return nil
    }

    /// Workspace switches must load protection before publishing the new status.
    func loadChangelistsIfNeeded() {
        let workspace = workspaceURLProvider?()?.standardizedFileURL
        guard workspace != changelistWorkspace else { return }
        changelistProjectionGeneration = UUID()
        changelistProjectionTask?.cancel()
        changelistProjectionTask = nil
        changelistProjectionPending = false
        changelistWorkspace = workspace
        changelists = GitLocalChangelists()
        changelistStorageFailed = false
        guard let workspace else { return }
        do {
            if let saved = try changelistStorage?.load(workspace: workspace) {
                guard saved.isValid else { throw GitWorkspaceCommitFailure("Invalid ChangeList metadata") }
                changelists = saved
            }
            scheduleChangelistProjection()
        } catch {
            changelistProjectionGeneration = UUID()
            changelistProjectionTask?.cancel()
            changelistProjectionTask = nil
            changelistProjectionPending = false
            changelistStorageFailed = true
        }
    }

    /// Status rows are projected as one batch away from the main thread. Until
    /// the exact snapshot returns, membership-sensitive actions remain disabled.
    func scheduleChangelistProjection() {
        guard changelistWorkspace != nil, !changelistStorageFailed else { return }
        changelistProjectionTask?.cancel()
        let generation = UUID()
        changelistProjectionGeneration = generation
        changelistProjectionPending = true
        let state = changelists
        let changes = gitChanges
        let workspace = changelistWorkspace
        let request = GitChangelistCoreRequest(state: state, changes: changes, action: .init(type: "rememberRenames"))
        changelistProjectionTask = Task { [weak self, service] in
            let result = await service.changelistProjection(request)
            guard let self, !Task.isCancelled, self.changelistProjectionGeneration == generation,
                  self.changelistWorkspace == workspace, !self.changelistStorageFailed,
                  self.changelists.metadataEquals(state), self.gitChanges == changes else { return }
            guard let result, self.publishChangelistProjection(result, changes: changes, expected: state) else {
                self.changelistStorageFailed = true
                self.changelistProjectionPending = false
                return
            }
            self.changelistProjectionPending = false
            self.changelistProjectionTask = nil
        }
    }

    func changelistStorageMatches(_ expected: GitLocalChangelists) -> Bool {
        guard let changelistStorage else { return true }
        guard let workspace = changelistWorkspace else { return false }
        guard let saved = try? changelistStorage.load(workspace: workspace) ?? GitLocalChangelists() else { return false }
        return saved.metadataEquals(expected)
    }

    func verifyChangelistStorageCurrent() -> Bool {
        guard changelistStorageMatches(changelists) else {
            changelistStorageFailed = true
            notify?(L10n.string("ChangeList storage is unavailable. Restore the saved data and reopen the workspace."))
            return false
        }
        return true
    }

    @discardableResult
    private func publishChangelistProjection(_ result: GitChangelistCoreProjection, changes: [GitChange], expected: GitLocalChangelists) -> Bool {
        guard let workspace = changelistWorkspace,
              let updated = result.state.local.withMembership(result.members, for: changes) else { return false }
        do {
            // Another window may have changed the same workspace while Core
            // was computing. Never publish or overwrite a newer snapshot.
            guard changelistStorageMatches(expected) else { return false }
            if !changelists.metadataEquals(updated) { try changelistStorage?.save(updated, workspace: workspace) }
            publishingChangelistProjection = true
            changelists = updated
            publishingChangelistProjection = false
            return true
        } catch {
            notify?(L10n.string("ChangeList storage is unavailable. Restore the saved data and reopen the workspace."))
            return false
        }
    }

    private func performChangelistAction(_ action: GitChangelistCoreRequest.Action) async -> Bool {
        loadChangelistsIfNeeded()
        guard !changelistEditingDisabled, verifyChangelistStorageCurrent(), let workspace = changelistWorkspace else { return false }
        let state = changelists
        let changes = gitChanges
        let generation = UUID()
        changelistProjectionGeneration = generation
        changelistProjectionTask?.cancel()
        changelistProjectionPending = true
        let request = GitChangelistCoreRequest(state: state, changes: changes, action: action)
        defer { if changelistProjectionGeneration == generation { changelistProjectionPending = false } }
        let result = await service.changelistProjection(request)
        guard !Task.isCancelled, changelistProjectionGeneration == generation,
              changelistWorkspace == workspace, changelists.metadataEquals(state), gitChanges == changes else { return false }
        guard let result else { return false }
        guard publishChangelistProjection(result, changes: changes, expected: state) else {
            changelistStorageFailed = true
            return false
        }
        return true
    }

    package func activateChangelist(_ id: String) async -> Bool {
        await performChangelistAction(.init(type: "activate", id: id))
    }

    /// Returns a localizable validation message; creation does not change the active list.
    package func saveChangelistName(_ name: String, id: String? = nil) async -> String? {
        let action = GitChangelistCoreRequest.Action(type: id == nil ? "create" : "rename", id: id ?? UUID().uuidString, name: name)
        if await performChangelistAction(action) { return nil }
        return changelistStorageFailed ? "ChangeList editing is unavailable." : "Use a unique, nonempty name of at most 100 characters."
    }

    package func removeChangelist(_ id: String) async {
        _ = await performChangelistAction(.init(type: "remove", id: id))
    }

    package func moveChanges(_ changes: [GitChange], toChangelist id: String) async {
        let files = changes.filter { gitChanges.contains($0) }.map(GitChangelistCoreRequest.File.init)
        _ = await performChangelistAction(.init(type: "move", id: id, files: files))
    }
}
