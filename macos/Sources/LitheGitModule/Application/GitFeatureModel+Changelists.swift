import Foundation

extension GitFeatureModel {
    package var changelistEditingDisabled: Bool {
        isCommitting || isStagingChanges || pendingSubmoduleCommitPlan != nil
            || (workspaceCommitAttempt != nil && workspaceCommitAttempt?.succeeded != true)
            || changelistStorageFailed
    }

    package var activeChangelistChanges: [GitChange] {
        gitChanges.filter { changelists.listID(for: $0) == changelists.activeID }
    }

    package var changelistCommitError: String? {
        if changelistStorageFailed { return "ChangeList storage is unavailable. Restore the saved data and reopen the workspace." }
        if gitChanges.contains(where: { $0.isStaged && changelists.listID(for: $0) != changelists.activeID }) {
            return "Other ChangeLists have staged files. Unstage them before committing the current ChangeList."
        }
        return nil
    }

    /// Workspace switches must load protection before publishing the new status.
    func loadChangelistsIfNeeded() {
        let workspace = workspaceURLProvider?()?.standardizedFileURL
        guard workspace != changelistWorkspace else { return }
        changelistWorkspace = workspace
        changelists = GitLocalChangelists()
        changelistStorageFailed = false
        guard let workspace else { return }
        do {
            if let saved = try changelistStorage?.load(workspace: workspace) {
                guard saved.isValid else { throw GitWorkspaceCommitFailure("Invalid ChangeList metadata") }
                changelists = saved
            }
        } catch { changelistStorageFailed = true }
    }

    func rememberChangelistRenames() {
        guard !changelistStorageFailed else { return }
        var updated = changelists
        updated.rememberRenames(gitChanges)
        if updated != changelists { saveChangelists(updated) }
    }

    @discardableResult
    private func saveChangelists(_ updated: GitLocalChangelists) -> Bool {
        guard !changelistStorageFailed, let workspace = changelistWorkspace else { return false }
        do {
            try changelistStorage?.save(updated, workspace: workspace)
            changelists = updated
            return true
        } catch {
            changelistStorageFailed = true
            notify?("ChangeList storage is unavailable. Restore the saved data and reopen the workspace.")
            return false
        }
    }

    package func activateChangelist(_ id: String) {
        loadChangelistsIfNeeded()
        guard !changelistEditingDisabled, changelists.lists.contains(where: { $0.id == id }) else { return }
        var updated = changelists
        updated.activeID = id
        saveChangelists(updated)
    }

    /// Returns a localizable validation message; creation does not change the active list.
    package func saveChangelistName(_ name: String, id: String? = nil) -> String? {
        loadChangelistsIfNeeded()
        guard !changelistEditingDisabled else { return "ChangeList editing is unavailable." }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { return "Enter a ChangeList name (1–100 characters)." }
        guard !changelists.lists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return "A ChangeList with this name already exists."
        }
        var updated = changelists
        if let id {
            guard id != GitLocalChangelists.defaultID, let index = updated.lists.firstIndex(where: { $0.id == id }) else {
                return "The default ChangeList cannot be renamed."
            }
            updated.lists[index].name = name
        } else {
            updated.lists.append(GitLocalChangelist(id: UUID().uuidString, name: name))
        }
        return saveChangelists(updated) ? nil : "ChangeList editing is unavailable."
    }

    package func removeChangelist(_ id: String) {
        loadChangelistsIfNeeded()
        guard !changelistEditingDisabled, id != GitLocalChangelists.defaultID else { return }
        var updated = changelists
        updated.lists.removeAll { $0.id == id }
        for root in Array(updated.assignments.keys) {
            updated.assignments[root] = updated.assignments[root]?.filter { $0.value != id }
        }
        if updated.activeID == id { updated.activeID = GitLocalChangelists.defaultID }
        saveChangelists(updated)
    }

    package func moveChanges(_ changes: [GitChange], toChangelist id: String) {
        loadChangelistsIfNeeded()
        guard !changelistEditingDisabled else { return }
        var updated = changelists
        updated.move(changes.filter { gitChanges.contains($0) }, to: id)
        saveChangelists(updated)
    }
}
