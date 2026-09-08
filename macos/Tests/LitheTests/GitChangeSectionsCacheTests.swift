import Foundation
import Testing
@testable import Lithe
@testable import LitheGitModule

/// The sidebar's four change sections come from one cached pass. A wrong
/// partition silently files a change under the wrong header or breaks the
/// commit affordance, so the split and the conflict filter are pinned here.
@MainActor
@Suite("Git change sections")
struct GitChangeSectionsCacheTests {
    private let root = URL(fileURLWithPath: "/tmp/repo")

    private func change(
        _ path: String,
        indexStatus: Character = " ",
        workTreeStatus: Character = "M"
    ) -> GitChange {
        GitChange(
            repositoryRoot: root,
            path: path,
            originalPath: nil,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus
        )
    }

    @Test
    func addedChangesSplitAwayFromTrackedOnes() {
        let added = change("new.swift", indexStatus: "A", workTreeStatus: " ")
        let modified = change("existing.swift")
        let cache = GitChangeSectionsCache()

        let sections = cache.sections(changes: [added, modified], conflictFilterPaths: [])

        #expect(sections.displayed.count == 2)
        #expect(sections.added.map(\.path) == ["new.swift"])
        #expect(sections.tracked.map(\.path) == ["existing.swift"])
    }

    @Test
    func aConflictFilterHidesEverythingOutsideIt() {
        let cache = GitChangeSectionsCache()
        let changes = [change("a.swift"), change("b.swift"), change("c.swift")]

        let sections = cache.sections(
            changes: changes,
            conflictFilterPaths: ["b.swift"]
        )

        #expect(sections.displayed.map(\.path) == ["b.swift"])
        #expect(sections.tracked.map(\.path) == ["b.swift"])
    }

    @Test
    func stagedIgnoresTheConflictFilter() {
        // The commit affordances ask "is anything staged" about the repository,
        // not about whatever subset the conflict banner is showing.
        let staged = change("staged.swift", indexStatus: "M", workTreeStatus: " ")
        let other = change("other.swift")
        let cache = GitChangeSectionsCache()

        let sections = cache.sections(
            changes: [staged, other],
            conflictFilterPaths: ["other.swift"]
        )

        #expect(sections.displayed.map(\.path) == ["other.swift"])
        #expect(sections.staged.map(\.path) == ["staged.swift"])
    }

    @Test
    func aChangedListInvalidatesTheCache() {
        let cache = GitChangeSectionsCache()
        let first = cache.sections(changes: [change("a.swift")], conflictFilterPaths: [])
        #expect(first.displayed.count == 1)

        let second = cache.sections(
            changes: [change("a.swift"), change("b.swift")],
            conflictFilterPaths: []
        )
        #expect(second.displayed.count == 2)
    }

    @Test
    func aChangedFilterInvalidatesTheCacheEvenWhenTheChangesMatch() {
        // Both inputs key the cache; only comparing the change list would leave
        // the conflict banner showing a stale file list.
        let cache = GitChangeSectionsCache()
        let changes = [change("a.swift"), change("b.swift")]

        _ = cache.sections(changes: changes, conflictFilterPaths: [])
        let filtered = cache.sections(changes: changes, conflictFilterPaths: ["a.swift"])

        #expect(filtered.displayed.map(\.path) == ["a.swift"])
    }
}
