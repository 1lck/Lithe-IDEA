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
        at repositoryRoot: URL? = nil,
        indexStatus: Character = " ",
        workTreeStatus: Character = "M"
    ) -> GitChange {
        GitChange(
            repositoryRoot: repositoryRoot ?? root,
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
    @Test
    func groupsDisplayedChangesByRepositoryInStableInputOrder() {
        let secondRoot = URL(fileURLWithPath: "/tmp/second-repo")
        let firstTracked = change("src/Main.swift")
        let secondAdded = change(
            "README.md",
            at: secondRoot,
            indexStatus: "?",
            workTreeStatus: "?"
        )
        let firstAdded = change(
            "notes.md",
            indexStatus: "?",
            workTreeStatus: "?"
        )
        let cache = GitChangeSectionsCache()

        let sections = cache.sections(
            changes: [firstTracked, secondAdded, firstAdded],
            conflictFilterPaths: []
        )

        #expect(sections.repositories.map(\.root) == [root, secondRoot])
        #expect(sections.repositories[0].changes.map(\.path) == ["src/Main.swift", "notes.md"])
        #expect(sections.repositories[0].tracked.map(\.path) == ["src/Main.swift"])
        #expect(sections.repositories[0].added.map(\.path) == ["notes.md"])
        #expect(sections.repositories[1].changes.map(\.path) == ["README.md"])
    }

    @Test
    func movingFilesRegroupsTheCacheWithoutChangingStatusOrHidingOtherLists() {
        let config = change("application.yaml")
        let code = change("feature.swift")
        let changes = [config, code]
        let cache = GitChangeSectionsCache()
        var lists = GitLocalChangelists()
        _ = cache.sections(changes: changes, conflictFilterPaths: [], changelists: lists)
        lists.lists.append(GitLocalChangelist(id: "local", name: "Local"))
        lists.move([config], to: "local")
        let sections = cache.sections(changes: changes, conflictFilterPaths: [], changelists: lists)
        #expect(sections.displayed == changes)
        #expect(sections.changelists.map(\.id) == ["default", "local"])
        #expect(sections.changelists[0].changes == [code])
        #expect(sections.repositories[0].changelists[1].changes == [config])
    }

    @Test
    func conflictFilterRemovesEmptyRepositories() {
        let secondRoot = URL(fileURLWithPath: "/tmp/second-repo")
        let first = change("first.swift")
        let second = change("second.swift", at: secondRoot)
        let cache = GitChangeSectionsCache()

        let sections = cache.sections(
            changes: [first, second],
            conflictFilterPaths: [second.path]
        )

        #expect(sections.repositories.map(\.root) == [secondRoot])
        #expect(sections.repositories[0].changes.map(\.path) == ["second.swift"])
    }

    @Test
    func everyHeaderAndChangeIsItsOwnRow() {
        // #1385: nesting a repository's rows inside one stack child made the lazy
        // list build all 5,000 rows at once. Each row must be a direct child.
        let other = URL(fileURLWithPath: "/tmp/other")
        let changes = [change("a.swift"), change("b.swift"), change("c.swift", at: other)]
        let cache = GitChangeSectionsCache()
        let sections = cache.sections(changes: changes, conflictFilterPaths: [])

        let rows = cache.rows(for: sections, groupsByRepository: true,
                              repositoryExpanded: [:], changelistExpanded: [:])
        #expect(rows.map(\.id) == [
            "repository:/tmp/repo", "changelist:/tmp/repo:default", changes[0].id, changes[1].id,
            "repository:/tmp/other", "changelist:/tmp/other:default", changes[2].id
        ])
        #expect(rows.filter(\.closesRepository).map(\.id) == [changes[1].id, changes[2].id])

        let collapsed = cache.rows(for: sections, groupsByRepository: true,
                                   repositoryExpanded: ["/tmp/repo": false],
                                   changelistExpanded: ["/tmp/other:default": false])
        #expect(collapsed.map(\.id) == [
            "repository:/tmp/repo", "repository:/tmp/other", "changelist:/tmp/other:default"
        ])
        #expect(collapsed.filter(\.closesRepository).map(\.id)
            == ["repository:/tmp/repo", "changelist:/tmp/other:default"])

        let single = cache.rows(for: sections, groupsByRepository: false,
                                repositoryExpanded: [:], changelistExpanded: [:])
        #expect(single.map(\.id) == ["changelist::default"] + changes.map(\.id))
    }

    @Test
    func listedUntrackedDirectoryContentsNestBelowTheirSummaryAndCountOnce() {
        func untracked(_ path: String, count: Int? = nil) -> GitChange {
            GitChange(repositoryRoot: root, path: path, originalPath: nil,
                      indexStatus: "?", workTreeStatus: "?", untrackedFileCount: count)
        }
        let changes = [
            untracked("target/", count: 120),
            untracked("target/a.json"),
            untracked("target/debug/", count: 119),
            untracked("target/debug/app"),
            change("z.swift")
        ]
        let section = GitChangeSectionsCache()
            .sections(changes: changes, conflictFilterPaths: []).changelists[0]

        #expect(section.depths == [0, 1, 1, 2, 0])
        #expect(section.fileCount == 121)
    }
}
