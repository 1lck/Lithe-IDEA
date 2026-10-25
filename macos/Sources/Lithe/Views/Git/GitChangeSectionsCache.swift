import Foundation
import LitheGitModule

/// Splits the working-tree changes into the sections the sidebar renders, once
/// per change of the underlying list.
///
/// `displayedChanges` was recomputed by `trackedChanges`, `addedChanges`, and
/// the empty-state check, so one body pass filtered the whole change list
/// several times over and then partitioned it twice more.
///
/// A reference box in `@State`, like `EditorViewportStore`, so caching cannot
/// invalidate the view that reads it.
@MainActor
final class GitChangeSectionsCache {
    struct ChangelistSection: Identifiable {
        let list: GitLocalChangelist
        /// Every change in the list, including the listed contents of expanded
        /// untracked directories directly after their summary.
        let changes: [GitChange]
        /// Expanded untracked directories above each change, parallel to `changes`.
        let depths: [Int]
        /// Files the changes stand for; listed contents are counted by their summary.
        let fileCount: Int
        var id: String { list.id }

        init(list: GitLocalChangelist, changes: [GitChange]) {
            self.list = list
            self.changes = changes
            depths = GitChangeSectionsCache.depths(of: changes)
            fileCount = zip(changes, depths).reduce(0) { $0 + ($1.1 == 0 ? $1.0.fileCount : 0) }
        }
    }

    struct RepositorySection: Identifiable {
        let root: URL
        let changelists: [ChangelistSection]
        let changes: [GitChange]
        let tracked: [GitChange]
        let added: [GitChange]

        var id: String { root.standardizedFileURL.path }
        var fileCount: Int { changelists.reduce(0) { $0 + $1.fileCount } }
    }

    /// One row of the change list. The list renders these directly in a lazy
    /// stack, so only visible rows are built however many changes exist.
    struct Row: Identifiable {
        enum Content {
            case repository(RepositorySection)
            /// `key` identifies the list's expansion state within its repository.
            case changelist(ChangelistSection, key: String)
            /// `depth` counts the expanded untracked directories above the change.
            case change(GitChange, depth: Int)
        }

        let content: Content
        /// Draws the divider that closes a repository group.
        var closesRepository = false

        var id: String {
            switch content {
            case .repository(let repository): "repository:" + repository.id
            case .changelist(_, let key): "changelist:" + key
            case .change(let change, _): change.id
            }
        }
    }

    struct Sections {
        /// All changes, minus anything hidden by an active conflict filter.
        let displayed: [GitChange]
        let tracked: [GitChange]
        let added: [GitChange]
        let staged: [GitChange]
        let repositories: [RepositorySection]
        let changelists: [ChangelistSection]
    }

    private var cachedChanges: [GitChange] = []
    private var cachedFilterPaths: Set<String> = []
    private var cachedChangelists: GitLocalChangelists?
    private var cached: Sections?
    private var sectionsGeneration = 0
    private var cachedRowsKey: RowsKey?
    private var cachedRows: [Row] = []

    private struct RowsKey: Equatable {
        let sectionsGeneration: Int
        let groupsByRepository: Bool
        let repositoryExpanded: [String: Bool]
        let changelistExpanded: [String: Bool]
    }

    func sections(
        changes: [GitChange],
        conflictFilterPaths: Set<String>,
        changelists: GitLocalChangelists = GitLocalChangelists()
    ) -> Sections {
        if let cached, cachedChanges == changes, cachedFilterPaths == conflictFilterPaths, cachedChangelists == changelists {
            return cached
        }

        var displayed: [GitChange] = []
        var tracked: [GitChange] = []
        var added: [GitChange] = []
        var staged: [GitChange] = []
        var repositoryOrder: [String] = []
        var repositoryChanges: [String: [GitChange]] = [:]
        var repositoryTracked: [String: [GitChange]] = [:]
        var repositoryAdded: [String: [GitChange]] = [:]
        displayed.reserveCapacity(changes.count)

        for change in changes {
            // `staged` intentionally ignores the conflict filter, matching the
            // commit-affordance checks that read it.
            if change.isStaged { staged.append(change) }
            guard conflictFilterPaths.isEmpty || conflictFilterPaths.contains(change.path) else {
                continue
            }
            displayed.append(change)
            let repositoryID = change.repositoryRoot.standardizedFileURL.path
            if repositoryChanges[repositoryID] == nil {
                repositoryOrder.append(repositoryID)
            }
            repositoryChanges[repositoryID, default: []].append(change)
            if change.kind == .added {
                added.append(change)
                repositoryAdded[repositoryID, default: []].append(change)
            } else {
                tracked.append(change)
                repositoryTracked[repositoryID, default: []].append(change)
            }
        }

        let repositories = repositoryOrder.compactMap { repositoryID -> RepositorySection? in
            guard let changes = repositoryChanges[repositoryID],
                  let root = changes.first?.repositoryRoot else { return nil }
            return RepositorySection(
                root: root,
                changelists: listSections(changes, state: changelists),
                changes: changes,
                tracked: repositoryTracked[repositoryID] ?? [],
                added: repositoryAdded[repositoryID] ?? []
            )
        }
        let sections = Sections(
            displayed: displayed,
            tracked: tracked,
            added: added,
            staged: staged,
            repositories: repositories,
            changelists: listSections(displayed, state: changelists)
        )
        cachedChangelists = changelists
        cachedChanges = changes
        cachedFilterPaths = conflictFilterPaths
        cached = sections
        sectionsGeneration &+= 1
        return sections
    }

    /// Flattens `sections` into visible rows. Collapsed repositories and lists
    /// contribute only their header; a collapsed untracked directory has no
    /// listed contents to begin with.
    func rows(
        for sections: Sections,
        groupsByRepository: Bool,
        repositoryExpanded: [String: Bool],
        changelistExpanded: [String: Bool]
    ) -> [Row] {
        let key = RowsKey(
            sectionsGeneration: sectionsGeneration,
            groupsByRepository: groupsByRepository,
            repositoryExpanded: repositoryExpanded,
            changelistExpanded: changelistExpanded
        )
        if key == cachedRowsKey { return cachedRows }

        var rows: [Row] = []
        func append(_ changelists: [ChangelistSection], repositoryID: String) {
            for section in changelists {
                let key = repositoryID + ":" + section.id
                rows.append(Row(content: .changelist(section, key: key)))
                guard changelistExpanded[key] ?? true else { continue }
                for (change, depth) in zip(section.changes, section.depths) {
                    rows.append(Row(content: .change(change, depth: depth)))
                }
            }
        }
        if groupsByRepository {
            for repository in sections.repositories {
                rows.append(Row(content: .repository(repository)))
                if repositoryExpanded[repository.id] ?? true {
                    append(repository.changelists, repositoryID: repository.id)
                }
                rows[rows.count - 1].closesRepository = true
            }
        } else {
            append(sections.changelists, repositoryID: "")
        }
        cachedRowsKey = key
        cachedRows = rows
        return rows
    }

    /// Number of listed untracked directory summaries above each change.
    ///
    /// The feature model lists a summary's contents directly after it, so the
    /// open summaries form a stack and one pass suffices.
    nonisolated static func depths(of changes: [GitChange]) -> [Int] {
        var open: [GitChange] = []
        return changes.map { change in
            while let last = open.last, !last.containsUntrackedDescendant(change) { open.removeLast() }
            let depth = open.count
            if change.isUntrackedDirectory { open.append(change) }
            return depth
        }
    }

    private func listSections(_ changes: [GitChange], state: GitLocalChangelists) -> [ChangelistSection] {
        let grouped = Dictionary(grouping: changes) { state.listID(for: $0) }
        return state.lists.compactMap { list in
            guard let changes = grouped[list.id], !changes.isEmpty else { return nil }
            return ChangelistSection(list: list, changes: changes)
        }
    }
}
