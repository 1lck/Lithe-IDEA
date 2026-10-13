import Foundation

/// Local UI metadata, independent of the Git index. Core owns commit authorization.
package struct GitLocalChangelist: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package var name: String
    package var displayName: String { id == GitLocalChangelists.defaultID ? "Default ChangeList" : name }
}

package struct GitLocalChangelists: Codable, Equatable, Sendable {
    package init() {}
    package static let defaultID = "default"
    package var version = 1
    package var lists = [GitLocalChangelist(id: defaultID, name: "")]
    package var activeID = defaultID
    /// Repository/worktree root -> literal repository-relative path -> list ID.
    /// Keep assignments when a file becomes clean so local configuration stays protected.
    package var assignments: [String: [String: String]] = [:]

    package var isValid: Bool {
        let ids = Set(lists.map(\.id))
        return version == 1 && ids.count == lists.count && ids.contains(Self.defaultID)
            && ids.contains(activeID) && lists.allSatisfy {
                !$0.id.isEmpty && ($0.id == Self.defaultID || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } && assignments.allSatisfy { root, paths in
                !root.isEmpty && paths.allSatisfy { path, id in !path.isEmpty && ids.contains(id) }
            }
    }

    package func listID(for change: GitChange) -> String {
        let paths = assignments[change.repositoryRoot.standardizedFileURL.path] ?? [:]
        // A stale destination assignment must not override the renamed source.
        return renamedSourcePath(change).flatMap { paths[$0] } ?? paths[change.path] ?? Self.defaultID
    }

    package mutating func move(_ changes: [GitChange], to id: String) {
        guard lists.contains(where: { $0.id == id }) else { return }
        for change in changes {
            let root = change.repositoryRoot.standardizedFileURL.path
            for path in [change.path, renamedSourcePath(change)].compactMap({ $0 }) {
                assignments[root, default: [:]][path] = id
            }
        }
    }

    package mutating func rememberRenames(_ changes: [GitChange]) {
        let snapshot = self
        for change in changes where renamedSourcePath(change) != nil {
            let id = snapshot.listID(for: change)
            move([change], to: id)
        }
    }

    private func renamedSourcePath(_ change: GitChange) -> String? {
        // A copied file has its own membership; never move its unchanged source.
        change.indexStatus == "C" || change.workTreeStatus == "C" ? nil : change.originalPath
    }

    /// Translate local UI assignments into Core's immutable repository-ID scope.
    package func commitScope(repositories: [GitWorkspaceRepositoryBinding], changes: [GitChange]) -> GitWorkspaceCommitPathScope {
        var snapshot = self
        snapshot.rememberRenames(changes)
        let include = activeID != Self.defaultID
        var paths: [String: [String]] = [:]
        for repository in repositories {
            let assigned = snapshot.assignments[URL(fileURLWithPath: repository.root).standardizedFileURL.path] ?? [:]
            let selected = assigned.filter { include ? $0.value == activeID : $0.value != Self.defaultID }.keys.sorted()
            if !selected.isEmpty { paths[repository.id] = selected }
        }
        return GitWorkspaceCommitPathScope(include: include, paths: paths)
    }
}
