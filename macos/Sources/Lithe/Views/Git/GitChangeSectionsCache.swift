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
    struct Sections {
        /// All changes, minus anything hidden by an active conflict filter.
        let displayed: [GitChange]
        let tracked: [GitChange]
        let added: [GitChange]
        let staged: [GitChange]
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
        displayed.reserveCapacity(changes.count)

        for change in changes {
            // `staged` intentionally ignores the conflict filter, matching the
            // commit-affordance checks that read it.
            if change.isStaged { staged.append(change) }
            guard conflictFilterPaths.isEmpty || conflictFilterPaths.contains(change.path) else {
                continue
            }
            displayed.append(change)
            if change.kind == .added {
                added.append(change)
            } else {
                tracked.append(change)
            }
        }

        let sections = Sections(
            displayed: displayed,
            tracked: tracked,
            added: added,
            staged: staged
        )
        cachedChanges = changes
        cachedFilterPaths = conflictFilterPaths
        cached = sections
        return sections
    }
}
