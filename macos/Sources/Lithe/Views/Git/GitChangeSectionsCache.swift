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
    struct RepositorySection: Identifiable {
        let root: URL
        let changes: [GitChange]
        let tracked: [GitChange]
        let added: [GitChange]

        var id: String { root.standardizedFileURL.path }
    }

    struct Sections {
        /// All changes, minus anything hidden by an active conflict filter.
        let displayed: [GitChange]
        let tracked: [GitChange]
        let added: [GitChange]
        let staged: [GitChange]
        let repositories: [RepositorySection]
    }

    private var cachedChanges: [GitChange] = []
    private var cachedFilterPaths: Set<String> = []
    private var cached: Sections?

    func sections(
        changes: [GitChange],
        conflictFilterPaths: Set<String>
    ) -> Sections {
        if let cached, cachedChanges == changes, cachedFilterPaths == conflictFilterPaths {
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
            repositories: repositories
        )
        cachedChanges = changes
        cachedFilterPaths = conflictFilterPaths
        cached = sections
        return sections
    }
}
