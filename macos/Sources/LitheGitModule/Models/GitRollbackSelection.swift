import Foundation

/// A reviewed file set, independent of both row highlighting and the real index.
package struct GitRollbackSelection: Identifiable, Sendable {
    package let id = UUID()
    package let contextID: UUID
    package let changes: [GitChange]
    package private(set) var includedIDs: Set<GitChange.ID>
    package var deleteAddedFiles = false

    package init(contextID: UUID, changes: [GitChange], included: [GitChange]) {
        self.contextID = contextID
        // Git can report a staged deletion and an untracked copy with one ID.
        // Keep the tracked row so rolling it back restores HEAD, rather than
        // treating the retained disk copy as a newly added file.
        var seen: Set<GitChange.ID> = []
        let trackedIDs = Set(changes.filter { !$0.isUntracked }.map(\.id))
        self.changes = changes.filter { change in
            (!change.isUntracked || !trackedIDs.contains(change.id))
                && !(change.isUntrackedDirectory && changes.contains(where: { change.containsUntrackedDescendant($0) }))
                && seen.insert(change.id).inserted
        }
        let includedIDs = Set(included.map(\.id))
        let includedDirectories = included.filter(\.isUntrackedDirectory)
        self.includedIDs = Set(self.changes.filter { change in
            includedIDs.contains(change.id) || includedDirectories.contains(where: { $0.containsUntrackedDescendant(change) })
        }.map(\.id))
    }

    package var includedChanges: [GitChange] { changes.filter { includedIDs.contains($0.id) } }
    package var hasIncludedAdditions: Bool { includedChanges.contains(where: Self.isAddition) }

    package static func isAddition(_ change: GitChange) -> Bool {
        change.kind == .added || (change.indexStatus == "C" && !change.isConflicted)
    }

    /// A copied file owns only its destination; its source can have unrelated edits.
    package static func operationTarget(_ change: GitChange) -> GitChange {
        guard change.indexStatus == "C" || change.workTreeStatus == "C" else { return change }
        return GitChange(repositoryRoot: change.repositoryRoot, path: change.path, originalPath: nil,
            indexStatus: change.indexStatus, workTreeStatus: change.workTreeStatus,
            submodule: change.submodule, canToggleStaging: change.canToggleStaging,
            untrackedFileCount: change.untrackedFileCount)
    }

    package mutating func toggle(_ changes: [GitChange]) {
        let ids = Set(changes.map(\.id))
        if ids.isSubset(of: includedIDs) { includedIDs.subtract(ids) }
        else { includedIDs.formUnion(ids) }
    }

    /// Commit inclusion wins over the current diff's single highlighted row.
    package static func initialTargets(changes: [GitChange], selectedIDs: Set<GitChange.ID>) -> [GitChange] {
        let checked = changes.filter(\.isStaged)
        if !checked.isEmpty { return checked }
        let selected = changes.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? changes : selected
    }
}
