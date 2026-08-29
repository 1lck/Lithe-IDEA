import Foundation
@testable import Lithe
@testable import LitheGitModule
import Testing

/// Guards the pure section builders behind the Git Log filter popovers:
/// deterministic grouping, ordering, query matching, and pinned reset entries
/// (issue #302 regression risk: unbounded native menus returning by accident).
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

        #expect(menu.reset.title == "All Branches")
        // Starred shortcuts: the checked-out branch first, then its upstream.
        #expect(menu.starred.map(\.rowTitle) == ["main", "origin/main"])
        #expect(menu.starred.allSatisfy { $0.rowIsStarred })

        // Non-empty groups only, ordered Local, remotes by name, Tags.
        #expect(menu.groups.map(\.id) == ["local", "remote:origin", "tags"])
        #expect(menu.groups.map(\.title) == ["Local", "origin/…", "Tags"])

        // Flyout children keep full short names; locals sort the current
        // branch first and keep their upstream as detail.
        #expect(menu.groups[0].children.map(\.rowTitle) == ["main", "feature/login"])
        #expect(menu.groups[0].children[0].rowDetail == "origin/main")
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
    func branchSectionsGroupAndOrderReferences() {
        let references = [
            reference("origin/preview", kind: .remote),
            reference("v1.0.0", kind: .tag),
            reference("feature/login"),
            reference("main", isCurrent: true, upstream: "origin/main"),
            reference("feature/search"),
        ]

        let sections = GitLogFilterList.branchSections(references: references, query: "")

        // The pinned reset entry stays above every group.
        #expect(sections.first?.title == nil)
        #expect(sections.first?.items.map(\.rowTitle) == ["All Branches"])

        // Ungrouped locals first (current branch leading), then namespaces,
        // remotes, and tags.
        let groups = Array(sections.dropFirst())
        #expect(groups.map(\.title) == [nil, "feature", "Remote", "Tags"])
        #expect(groups.first?.items.map(\.rowTitle) == ["main"])

        // Namespaced locals show their leaf name, sorted within the group.
        let feature = groups.first { $0.title == "feature" }
        #expect(feature?.items.map(\.rowTitle) == ["login", "search"])

        // Remotes without upstream keep their kind label as detail.
        let remote = groups.first { $0.title == "Remote" }
        #expect(remote?.items.first?.rowDetail == "Remote")
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
}
