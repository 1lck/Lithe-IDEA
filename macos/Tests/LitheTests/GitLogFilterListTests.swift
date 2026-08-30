import Foundation
@testable import Lithe
@testable import LitheGitModule
import Testing

/// Guards the pure section builders behind the Git Log filter popovers:
/// deterministic grouping, ordering, query matching, pinned reset entries,
/// and identical per-row rules across browse and search modes (issue #302
/// regression risk: unbounded native menus returning by accident).
struct GitLogFilterListTests {
    private func reference(
        _ shortName: String,
        kind: GitReferenceKind = .local,
        isCurrent: Bool = false,
        upstream: String? = nil
    ) -> GitReference {
        let prefix: String
        switch kind {
        case .local: prefix = "refs/heads"
        case .remote: prefix = "refs/remotes"
        case .tag: prefix = "refs/tags"
        }
        return GitReference(
            fullName: "\(prefix)/\(shortName)",
            shortName: shortName,
            kind: kind,
            isCurrent: isCurrent,
            upstreamShortName: upstream
        )
    }

    @Test
    func branchMenuBuildsStarredShortcutsAndFlyoutGroups() {
        let references = [
            reference("origin/preview", kind: .remote),
            reference("v1.0.0", kind: .tag),
            reference("feature/login"),
            reference("main", isCurrent: true, upstream: "origin/main"),
            reference("origin/main", kind: .remote),
        ]

        let menu = GitLogFilterList.branchMenu(references: references)

        // The reset entry is an explicit kind with a localized label.
        #expect(menu.reset.kind == .allBranches)
        #expect(menu.reset.rowTitleKey != nil)

        // Starred shortcuts: the checked-out branch first, then its upstream.
        #expect(menu.starred.map(\.rowTitle) == ["main", "origin/main"])
        #expect(menu.starred.allSatisfy { $0.rowIsStarred })
        #expect(menu.starred.allSatisfy {
            if case .starred = $0.kind { return true }
            return false
        })

        // Non-empty groups only, ordered Local, remotes by name, Tags.
        #expect(menu.groups.map(\.id) == ["local", "remote:origin", "tags"])
        #expect(menu.groups.map(\.title) == ["Local", "origin/…", "Tags"])
        // Fixed labels localize; data-derived remote titles do not.
        #expect(menu.groups.map { $0.titleKey != nil } == [true, false, true])

        // Flyout children keep full short names; locals sort the current
        // branch first and keep their upstream as detail.
        #expect(menu.groups[0].children.map(\.rowTitle) == ["main", "feature/login"])
        #expect(menu.groups[0].children[0].rowDetail == "origin/main")
        #expect(menu.groups[0].children[1].rowDetail == nil)
        #expect(menu.groups[1].children.map(\.rowTitle) == ["origin/main", "origin/preview"])
        #expect(menu.groups[2].children.map(\.rowTitle) == ["v1.0.0"])
    }

    @Test
    func branchMenuOmitsEmptyGroupsAndStarredWithoutCurrentBranch() {
        let references = [
            reference("origin/preview", kind: .remote),
            reference("develop"),
        ]

        let menu = GitLogFilterList.branchMenu(references: references)

        #expect(menu.starred.isEmpty)
        #expect(menu.groups.map(\.id) == ["local", "remote:origin"])
        // A repository without locals or remotes still yields the Tags group.
        let tagsOnly = GitLogFilterList.branchMenu(references: [
            reference("v1.0.0", kind: .tag),
        ])
        #expect(tagsOnly.groups.map(\.id) == ["tags"])
        #expect(tagsOnly.groups[0].title == "Tags")
    }

    @Test
    func referenceRowsRenderIdenticallyAcrossBrowseAndSearchModes() {
        // Regression for the review's mode-inconsistency finding: the same
        // branch must render with the same title and detail whether the user
        // is browsing groups or filtering by a query.
        let references = [
            reference("feature/login"),
            reference("origin/preview", kind: .remote),
            reference("main", isCurrent: true, upstream: "origin/main"),
            reference("origin/main", kind: .remote),
        ]
        let menu = GitLogFilterList.branchMenu(references: references)
        let sections = GitLogFilterList.branchSections(references: references, query: "")

        for item in menu.groups.flatMap(\.children) {
            let searchItem = sections.flatMap(\.items).first { $0.id == item.id }
            #expect(searchItem != nil)
            #expect(searchItem?.rowTitle == item.rowTitle)
            #expect(searchItem?.rowDetail == item.rowDetail)
            #expect(searchItem?.rowIsStarred == item.rowIsStarred)
        }

        // Remotes carry no kind label in either mode; locals surface only
        // their upstream as detail.
        let login = sections.flatMap(\.items).first { $0.rowTitle == "feature/login" }
        #expect(login?.rowDetail == nil)
        let remote = sections.flatMap(\.items).first { $0.rowTitle == "origin/preview" }
        #expect(remote?.rowDetail == nil)
    }

    @Test
    func branchSectionsCarryPinnedRegionWithResetAndStarredRows() {
        let references = [
            reference("origin/main", kind: .remote),
            reference("main", isCurrent: true, upstream: "origin/main"),
        ]

        let sections = GitLogFilterList.branchSections(references: references, query: "")

        // The pinned region leads with the reset entry and the starred
        // shortcuts, and only it may render the trailing divider.
        #expect(sections.first?.isPinned == true)
        #expect(sections.first?.items.map(\.rowTitle) == ["All Branches", "main", "origin/main"])
        #expect(sections.dropFirst().allSatisfy { !$0.isPinned })
        #expect(sections.dropFirst().map(\.title) == [nil, "Remote"])
    }

    @Test
    func branchSectionsFilterPinnedRowsByQueryTitle() {
        let references = [
            reference("origin/main", kind: .remote),
            reference("main", isCurrent: true, upstream: "origin/main"),
        ]

        // The starred shortcuts survive a matching query and disappear on a
        // non-matching one, exactly like the reset entry.
        let matching = GitLogFilterList.branchSections(references: references, query: "main")
        #expect(matching.first?.isPinned == true)
        #expect(matching.first?.items.map(\.rowTitle) == ["main", "origin/main"])

        let nonMatching = GitLogFilterList.branchSections(references: references, query: "zzz")
        #expect(nonMatching.first { $0.isPinned } == nil)
    }

    @Test
    func branchSectionsGroupAndOrderReferences() {
        let references = [
            reference("origin/preview", kind: .remote),
            reference("v1.0.0", kind: .tag),
            reference("feature/login"),
            reference("main", isCurrent: true, upstream: "origin/main"),
            reference("feature/search"),
        ]

        let sections = GitLogFilterList.branchSections(references: references, query: "")

        // Ungrouped locals first (current branch leading), then namespaces,
        // remotes, and tags.
        let groups = sections.dropFirst().filter { !$0.isPinned }
        #expect(groups.map(\.title) == [nil, "feature", "Remote", "Tags"])
        #expect(groups.first?.items.map(\.rowTitle) == ["main"])

        // Reference rows keep full names inside namespace groups.
        let feature = groups.first { $0.title == "feature" }
        #expect(feature?.items.map(\.rowTitle) == ["feature/login", "feature/search"])
    }

    @Test
    func branchSectionsMatchQueryAgainstNameAndUpstream() {
        let references = [
            reference("main", isCurrent: true, upstream: "origin/preview"),
            reference("release/2.0", kind: .remote),
            reference("v2-preview", kind: .tag),
        ]

        // Matching is case-insensitive across short names and upstreams; the
        // pinned entry is hidden unless the query matches its title.
        let matched = GitLogFilterList.branchSections(references: references, query: "PREVIEW")
        #expect(matched.flatMap(\.items).map(\.rowTitle) == ["main", "v2-preview"])

        let resetOnly = GitLogFilterList.branchSections(references: [], query: "all")
        #expect(resetOnly.flatMap(\.items).map(\.rowTitle) == ["All Branches"])
    }

    @Test
    func authorSectionsPinResetEntriesAndSortAuthors() {
        let authors = [
            GitLogAuthorOption(id: "bob|b@example.com", name: "Bob", email: "b@example.com"),
            GitLogAuthorOption(id: "carol|c@example.com", name: "carol", email: "c@example.com"),
            GitLogAuthorOption(id: "alice|a@example.com", name: "Alice", email: "a@example.com"),
        ]

        let sections = GitLogFilterList.authorSections(authors: authors, query: "")

        #expect(sections.map(\.id) == ["pinned", "authors"])
        #expect(sections[0].isPinned)
        #expect(!sections[1].isPinned)
        #expect(sections[0].items.map(\.rowTitle) == ["All Users", "Me"])
        #expect(sections[1].items.map(\.rowTitle) == ["Alice", "Bob", "carol"])
    }

    @Test
    func authorSectionsMatchQueryAgainstNameAndEmail() {
        let authors = [
            GitLogAuthorOption(id: "bob|b@example.com", name: "Bob", email: "b@example.com"),
            GitLogAuthorOption(id: "dana|d@example.com", name: "Dana", email: "d@example.com"),
        ]

        let sections = GitLogFilterList.authorSections(authors: authors, query: "D@EXAMPLE")
        #expect(sections.flatMap(\.items).map(\.rowTitle) == ["Dana"])
    }

    @Test
    func authorFilterItemsMapBackToSelections() {
        let resetEntry = GitLogFilterList.authorSections(authors: [], query: "all")
            .flatMap(\.items)
            .first
        #expect(resetEntry?.kind == .allUsers)
        #expect(resetEntry?.selection == nil)

        let meEntry = GitLogFilterList.authorSections(authors: [], query: "me")
            .flatMap(\.items)
            .first
        #expect(meEntry?.kind == .currentUser)
        #expect(meEntry?.selection == .currentUser)

        let authorSections = GitLogFilterList.authorSections(
            authors: [GitLogAuthorOption(id: "a|a@example.com", name: "Ada", email: "a@example.com")],
            query: "ada"
        )
        let authorEntry = authorSections.flatMap(\.items).first
        #expect(authorEntry?.selection == .author(name: "Ada", email: "a@example.com"))
    }

    @Test
    func filterItemsMatchSelectedState() {
        let selectedBranch = reference("main", isCurrent: true)

        #expect(GitLogBranchFilterItem.allBranches.matches(selected: nil))
        #expect(!GitLogBranchFilterItem.allBranches.matches(selected: selectedBranch))
        #expect(GitLogBranchFilterItem.reference(selectedBranch).matches(selected: selectedBranch))
        #expect(!GitLogBranchFilterItem.reference(selectedBranch).matches(selected: nil))
        #expect(GitLogBranchFilterItem.starred(selectedBranch).matches(selected: selectedBranch))

        #expect(GitLogAuthorFilterItem.allUsers.matches(selected: nil))
        #expect(!GitLogAuthorFilterItem.allUsers.matches(selected: .currentUser))
        #expect(GitLogAuthorFilterItem.currentUser.matches(selected: .currentUser))
        #expect(GitLogAuthorFilterItem.author(name: "Ada", email: "a@example.com")
            .matches(selected: .author(name: "Ada", email: "a@example.com")))
        #expect(!GitLogAuthorFilterItem.author(name: "Ada", email: "a@example.com")
            .matches(selected: .currentUser))
    }

    @Test
    func fixedLabelsMatchQueriesByKeyAndLocalizedText() {
        // The label must be findable through either wording so a zh-Hans user
        // searching the displayed text still reaches the pinned entry.
        let label = GitLogFilterFixedLabel(key: "All Branches")

        #expect(label.matches("All Branches"))
        #expect(label.matches("all br"))
        #expect(label.matches("全部分支", localizedTitle: "全部分支"))
        #expect(label.matches("部分", localizedTitle: "全部分支"))
        #expect(!label.matches("xyz", localizedTitle: "全部分支"))

        // Data rows never pick up the localized fallback; they match names.
        let item = GitLogBranchFilterItem.reference(reference("feature/login"))
        #expect(item.matches(query: "login"))
        #expect(!item.matches(query: "全部分支"))
    }

    @Test
    func zhHansTableKeepsFixedFilterLabelsTranslated() throws {
        // Pin the zh-Hans table against copy edits that drop or rename the
        // fixed filter labels: search matching relies on these keys resolving
        // to localized text in the app.
        let testFile = URL(fileURLWithPath: #filePath)
        let stringsURL = testFile
            .deletingLastPathComponent()   // LitheTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: stringsURL) as? [String: String])

        for key in ["All Branches", "All Users", "Me", "Search users", "No matching users"] {
            #expect(table[key]?.isEmpty == false, "missing zh-Hans translation for \(key)")
        }
    }
}
