import SwiftUI
import LitheGitModule

// The Git Log filter bar previously used native `Menu` controls for its Branch
// and User filters. With many references or authors NSMenu grows into a
// screen-height list without any size constraint (issue #302). The types in
// this file back bounded, searchable, anchored popover replacements shaped
// like IntelliJ IDEA's log filter menus: a compact first level with starred
// shortcuts and group flyouts for branches, and a flat searchable list for
// authors.

/// The user-selection state of the Git Log author filter.
enum GitLogAuthorSelection: Hashable {
    case currentUser
    case author(name: String, email: String)

    var displayName: String {
        switch self {
        case .currentUser:
            return "Me"
        case .author(let name, _):
            return name
        }
    }

    var exactAuthor: GitIdentity? {
        switch self {
        case .currentUser:
            return nil
        case .author(let name, let email):
            return GitIdentity(name: name, email: email)
        }
    }
}

/// One distinct commit author offered by the Git Log author filter.
struct GitLogAuthorOption: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
}

/// A row a Git Log filter popover knows how to render.
protocol GitLogFilterRow: Identifiable {
    var rowTitle: String { get }
    /// Localized fixed label for the title, or `nil` when `rowTitle` is a
    /// data-derived name that must render verbatim.
    var rowTitleKey: LocalizedStringKey? { get }
    var rowDetail: String? { get }
    var rowSystemImage: String { get }
    /// Starred rows use the accent color for their icon, mirroring IDEA's
    /// starred branch shortcuts.
    var rowIsStarred: Bool { get }
}

extension GitLogFilterRow {
    var rowTitleKey: LocalizedStringKey? { nil }
    var rowIsStarred: Bool { false }
}

/// A region of a flat Git Log filter popover. Pinned regions hold reset and
/// starred shortcut rows and end with a divider before grouped content; a
/// `nil` title marks an untitled region such as ungrouped local branches.
struct GitLogFilterSection<Row: GitLogFilterRow>: Identifiable {
    let id: String
    let title: String?
    /// Localized fixed label for the title, or `nil` for data-derived
    /// namespace titles that render verbatim.
    let titleKey: LocalizedStringKey?
    let systemImage: String?
    let isPinned: Bool
    let items: [Row]
}

/// The fixed label of a pinned filter row. The English key is the single
/// source of truth: it renders through Localizable.strings and joins query
/// matching together with the resolved localized text, so a search hits the
/// row by either wording.
struct GitLogFilterFixedLabel: Hashable {
    let key: String

    var titleKey: LocalizedStringKey { LocalizedStringKey(key) }

    /// Display text resolved in the main bundle. Unit tests run without the
    /// app strings bundle, where this resolves back to the key itself.
    var localizedTitle: String {
        NSLocalizedString(key, comment: "Git Log filter fixed row")
    }

    /// A query matches the English key or the localized display text.
    func matches(_ query: String, localizedTitle override: String? = nil) -> Bool {
        if query.isEmpty { return true }
        if key.localizedCaseInsensitiveContains(query) { return true }
        let localized = override ?? localizedTitle
        return localized.localizedCaseInsensitiveContains(query)
    }
}

/// What a branch filter row represents. The kind replaces sentinel values so
/// reset entries, starred shortcuts, and reference rows are distinguishable
/// without magic strings.
struct GitLogBranchFilterItem: GitLogFilterRow, Identifiable, Hashable {
    enum Kind: Hashable {
        /// The pinned entry that clears the reference filter.
        case allBranches
        /// A starred shortcut for the current checkout or its upstream.
        case starred(reference: GitReference)
        /// A concrete reference listed inside a group.
        case reference(GitReference)
    }

    static let allBranchesLabel = GitLogFilterFixedLabel(key: "All Branches")

    let kind: Kind
    let detail: String?

    private init(kind: Kind, detail: String?) {
        self.kind = kind
        self.detail = detail
    }

    var id: String {
        switch kind {
        case .allBranches:
            return "all-branches"
        case .starred(let reference):
            return "starred:\(reference.fullName)"
        case .reference(let reference):
            return reference.fullName
        }
    }

    var reference: GitReference? {
        switch kind {
        case .allBranches:
            return nil
        case .starred(let reference), .reference(let reference):
            return reference
        }
    }

    var rowTitle: String {
        switch kind {
        case .allBranches:
            return Self.allBranchesLabel.localizedTitle
        case .starred(let reference), .reference(let reference):
            return reference.shortName
        }
    }

    var rowDetail: String? { detail }

    var rowIsStarred: Bool {
        if case .starred = kind { return true }
        return false
    }

    var rowTitleKey: LocalizedStringKey? {
        guard case .allBranches = kind else { return nil }
        return Self.allBranchesLabel.titleKey
    }

    var rowSystemImage: String {
        switch kind {
        case .allBranches:
            return "point.3.connected.trianglepath.dotted"
        case .starred:
            return "star.fill"
        case .reference(let reference):
            if reference.isCurrent { return "star.fill" }
            switch reference.kind {
            case .local: return "point.3.connected.trianglepath.dotted"
            case .remote: return "cloud"
            case .tag: return "tag"
            }
        }
    }

    /// Whether this row survives the given query: the reset entry matches its
    /// label (English key and localized text), data rows match their short
    /// name.
    func matches(query: String) -> Bool {
        switch kind {
        case .allBranches:
            return Self.allBranchesLabel.matches(query)
        case .starred(let reference), .reference(let reference):
            return query.isEmpty || reference.shortName.localizedCaseInsensitiveContains(query)
        }
    }

    /// Whether this row corresponds to the given selected reference; the
    /// reset entry matches only when nothing is selected.
    func matches(selected: GitReference?) -> Bool {
        switch kind {
        case .allBranches:
            return selected == nil
        case .starred(let reference), .reference(let reference):
            return selected?.id == reference.id
        }
    }

    static let allBranches = GitLogBranchFilterItem(kind: .allBranches, detail: nil)

    /// A starred shortcut row; shortcuts render names only, like IDEA.
    static func starred(_ reference: GitReference) -> GitLogBranchFilterItem {
        GitLogBranchFilterItem(kind: .starred(reference: reference), detail: nil)
    }

    /// A reference row. Reference rows keep their full short name in every
    /// mode and surface the upstream, when present, as detail.
    static func reference(_ reference: GitReference) -> GitLogBranchFilterItem {
        GitLogBranchFilterItem(
            kind: .reference(reference),
            detail: reference.upstreamShortName
        )
    }
}

/// An author filter row: a pinned reset entry, the current user, or a
/// concrete commit author.
struct GitLogAuthorFilterItem: Identifiable, Hashable, GitLogFilterRow {
    enum Kind: Hashable {
        case allUsers
        case currentUser
        case author(name: String, email: String)
    }

    static let allUsersLabel = GitLogFilterFixedLabel(key: "All Users")
    static let currentUserLabel = GitLogFilterFixedLabel(key: "Me")

    let kind: Kind
    let detail: String?

    private init(kind: Kind, detail: String?) {
        self.kind = kind
        self.detail = detail
    }

    var id: String {
        switch kind {
        case .allUsers: return "all-users"
        case .currentUser: return "current-user"
        case .author(let name, let email): return "\(name.lowercased())|\(email.lowercased())"
        }
    }

    var rowTitle: String {
        switch kind {
        case .allUsers:
            return Self.allUsersLabel.localizedTitle
        case .currentUser:
            return Self.currentUserLabel.localizedTitle
        case .author(let name, _):
            return name
        }
    }

    var rowDetail: String? { detail }

    var rowTitleKey: LocalizedStringKey? {
        switch kind {
        case .allUsers: return Self.allUsersLabel.titleKey
        case .currentUser: return Self.currentUserLabel.titleKey
        case .author: return nil
        }
    }

    var rowSystemImage: String {
        switch kind {
        case .allUsers: return "person.2"
        case .currentUser: return "person.fill"
        case .author: return "person"
        }
    }

    /// Whether this row survives the given query: pinned entries match their
    /// label (English key and localized text), authors match name and email.
    func matches(query: String) -> Bool {
        switch kind {
        case .allUsers:
            return Self.allUsersLabel.matches(query)
        case .currentUser:
            return Self.currentUserLabel.matches(query)
        case .author(let name, let email):
            return query.isEmpty ||
                name.localizedCaseInsensitiveContains(query) ||
                email.localizedCaseInsensitiveContains(query)
        }
    }

    /// The author-filter selection this row applies, or `nil` to clear it.
    var selection: GitLogAuthorSelection? {
        switch kind {
        case .allUsers:
            return nil
        case .currentUser:
            return .currentUser
        case .author(let name, let email):
            return .author(name: name, email: email)
        }
    }

    /// Whether this row corresponds to the given selection; the reset entry
    /// matches only when nothing is selected.
    func matches(selected: GitLogAuthorSelection?) -> Bool {
        switch kind {
        case .allUsers:
            return selected == nil
        case .currentUser:
            return selected == .currentUser
        case .author(let name, let email):
            return selected == .author(name: name, email: email)
        }
    }

    static let allUsers = GitLogAuthorFilterItem(kind: .allUsers, detail: nil)
    static let currentUser = GitLogAuthorFilterItem(kind: .currentUser, detail: nil)

    static func author(name: String, email: String) -> GitLogAuthorFilterItem {
        GitLogAuthorFilterItem(kind: .author(name: name, email: email), detail: email)
    }
}

/// A first-level group whose children open in the branch popover's flyout
/// column, mirroring IDEA's `origin/…` and `本地` submenu rows. Remote titles
/// are data-derived (`origin/…`) while `Local` and `Tags` are fixed labels.
struct GitLogBranchGroup: Identifiable {
    let id: String
    let title: String
    let titleKey: LocalizedStringKey?
    let systemImage: String
    let children: [GitLogBranchFilterItem]
}

/// The browse-mode content of the branch filter popover: a reset entry,
/// starred shortcuts, and one group per namespace whose children open in the
/// flyout column.
struct GitLogBranchMenu {
    let reset: GitLogBranchFilterItem
    let starred: [GitLogBranchFilterItem]
    let groups: [GitLogBranchGroup]
}

/// Pure builders for the Git Log filter popovers. Browse mode and search mode
/// follow the same per-row rules — full short names, upstream as detail,
/// starred shortcuts for the current branch and its upstream — so a branch
/// renders identically before and after the user types a query.
enum GitLogFilterList {
    /// Builds the browse-mode branch menu: starred shortcuts for the current
    /// branch and its upstream, then non-empty groups ordered Local,
    /// remotes by name (`origin/…`), and Tags.
    static func branchMenu(references: [GitReference]) -> GitLogBranchMenu {
        var groups: [GitLogBranchGroup] = []

        let locals = references.filter { $0.kind == .local }
        if !locals.isEmpty {
            groups.append(GitLogBranchGroup(
                id: "local",
                title: "Local",
                titleKey: "Local",
                systemImage: "arrow.triangle.branch",
                children: sortedReferenceItems(locals)
            ))
        }

        let remoteReferences = references.filter { $0.kind == .remote }
        let remotesByName = Dictionary(grouping: remoteReferences) { reference in
            reference.shortName.split(separator: "/").first.map(String.init) ?? reference.shortName
        }
        let remoteNames = remotesByName.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let remoteGroups: [GitLogBranchGroup] = remoteNames.map { remoteName in
            GitLogBranchGroup(
                id: "remote:\(remoteName)",
                title: "\(remoteName)/…",
                titleKey: nil,
                systemImage: "cloud",
                children: sortedReferenceItems(remotesByName[remoteName] ?? [])
            )
        }
        groups.append(contentsOf: remoteGroups)

        let tags = references.filter { $0.kind == .tag }
        if !tags.isEmpty {
            groups.append(GitLogBranchGroup(
                id: "tags",
                title: "Tags",
                titleKey: "Tags",
                systemImage: "tag",
                children: sortedReferenceItems(tags)
            ))
        }

        return GitLogBranchMenu(
            reset: .allBranches,
            starred: starredItems(references: references),
            groups: groups
        )
    }

    /// Builds flat branch sections for the popover's type-to-search mode. The
    /// pinned region carries the reset entry plus the starred shortcuts whose
    /// titles match the query; the rest groups by local namespace, remote,
    /// and tags. An empty query matches everything.
    static func branchSections(
        references: [GitReference],
        query: String
    ) -> [GitLogFilterSection<GitLogBranchFilterItem>] {
        var sections: [GitLogFilterSection<GitLogBranchFilterItem>] = []

        var pinned: [GitLogBranchFilterItem] = []
        if GitLogBranchFilterItem.allBranches.matches(query: query) {
            pinned.append(.allBranches)
        }
        pinned.append(contentsOf: starredItems(references: references).filter {
            $0.matches(query: query)
        })
        if !pinned.isEmpty {
            sections.append(GitLogFilterSection(
                id: "pinned",
                title: nil,
                titleKey: nil,
                systemImage: nil,
                isPinned: true,
                items: pinned
            ))
        }

        let matched = references.filter { reference in
            query.isEmpty ||
                reference.shortName.localizedCaseInsensitiveContains(query) ||
                reference.upstreamShortName?.localizedCaseInsensitiveContains(query) == true
        }

        let grouped = Dictionary(grouping: matched) { reference -> String in
            switch reference.kind {
            case .remote: return "Remote"
            case .tag: return "Tags"
            case .local:
                let components = reference.shortName.split(separator: "/")
                return components.count > 1 ? components.dropLast().joined(separator: "/") : ""
            }
        }

        let orderedGroups = grouped
            .map { title, groupReferences -> (title: String, kind: GitReferenceKind, references: [GitReference]) in
                (title, groupReferences[0].kind, groupReferences)
            }
            .sorted { lhs, rhs in
                // Mirror BranchSwitcherPopover: ungrouped locals first, then
                // by kind (local, remote, tag), then by group title.
                if lhs.title.isEmpty != rhs.title.isEmpty { return lhs.title.isEmpty }
                if lhs.kind != rhs.kind { return kindOrder(lhs.kind) < kindOrder(rhs.kind) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        sections.append(contentsOf: orderedGroups.map { group in
            GitLogFilterSection(
                id: "\(group.kind.rawValue):\(group.title)",
                title: group.title.isEmpty ? nil : group.title,
                titleKey: fixedSectionTitleKey(group.title),
                systemImage: groupSystemImage(group.kind),
                isPinned: false,
                items: sortedReferenceItems(group.references)
            )
        })
        return sections
    }

    /// Builds author sections: pinned "All Users" and "Me" reset entries
    /// followed by the authors sorted by name. The query matches names and
    /// emails case-insensitively; pinned entries only survive when the query
    /// matches their titles.
    static func authorSections(
        authors: [GitLogAuthorOption],
        query: String
    ) -> [GitLogFilterSection<GitLogAuthorFilterItem>] {
        var pinned: [GitLogAuthorFilterItem] = []
        if GitLogAuthorFilterItem.allUsers.matches(query: query) {
            pinned.append(.allUsers)
        }
        if GitLogAuthorFilterItem.currentUser.matches(query: query) {
            pinned.append(.currentUser)
        }

        let matched = authors.filter { author in
            query.isEmpty ||
                author.name.localizedCaseInsensitiveContains(query) ||
                author.email.localizedCaseInsensitiveContains(query)
        }
        let sorted = matched.sorted { lhs, rhs in
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            let byEmail = lhs.email.localizedCaseInsensitiveCompare(rhs.email)
            if byEmail != .orderedSame { return byEmail == .orderedAscending }
            return lhs.id < rhs.id
        }
        .map { author in
            GitLogAuthorFilterItem.author(name: author.name, email: author.email)
        }

        var sections: [GitLogFilterSection<GitLogAuthorFilterItem>] = []
        if !pinned.isEmpty {
            sections.append(GitLogFilterSection(
                id: "pinned",
                title: nil,
                titleKey: nil,
                systemImage: nil,
                isPinned: true,
                items: pinned
            ))
        }
        if !sorted.isEmpty {
            sections.append(GitLogFilterSection(
                id: "authors",
                title: nil,
                titleKey: nil,
                systemImage: nil,
                isPinned: false,
                items: sorted
            ))
        }
        return sections
    }

    /// Starred shortcuts for the checked-out branch and, when it exists as a
    /// remote reference, its upstream. Shared by both modes so the shortcuts
    /// never disappear while searching.
    private static func starredItems(references: [GitReference]) -> [GitLogBranchFilterItem] {
        guard let current = references.first(where: { $0.isCurrent }) else { return [] }
        var items = [GitLogBranchFilterItem.starred(current)]
        if let upstreamName = current.upstreamShortName,
           let upstream = references.first(where: { $0.kind == .remote && $0.shortName == upstreamName }) {
            items.append(.starred(upstream))
        }
        return items
    }

    /// Reference rows sort the current branch first, then by short name.
    private static func sortedReferenceItems(
        _ references: [GitReference]
    ) -> [GitLogBranchFilterItem] {
        references
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
            }
            .map { GitLogBranchFilterItem.reference($0) }
    }

    private static func fixedSectionTitleKey(_ title: String) -> LocalizedStringKey? {
        switch title {
        case "Remote": return "Remote"
        case "Tags": return "Tags"
        default: return nil
        }
    }

    private static func kindOrder(_ kind: GitReferenceKind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .tag: 2
        }
    }

    private static func groupSystemImage(_ kind: GitReferenceKind) -> String {
        switch kind {
        case .local: return "folder"
        case .remote: return "network"
        case .tag: return "tag"
        }
    }
}

/// Shared search field for Git Log filter popovers; focuses itself on appear
/// so typing filters immediately.
struct GitLogFilterSearchBar: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .litheIconButton()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(LitheTheme.toolHeader)
        .onAppear { focused = true }
    }
}

/// Shared rendering for one selectable filter row.
struct GitLogFilterRowView<Row: GitLogFilterRow>: View {
    let item: Row
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.rowSystemImage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.rowIsStarred ? LitheTheme.warning : LitheTheme.secondaryText)
                    .frame(width: 17)
                titleText
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let detail = item.rowDetail {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitheTheme.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(isSelected ? LitheTheme.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    @ViewBuilder
    private var titleText: some View {
        if let titleKey = item.rowTitleKey {
            Text(titleKey)
        } else {
            Text(verbatim: item.rowTitle)
        }
    }
}

/// Shared grouped-list body for flat filter popovers: section headers plus
/// row rendering with an empty-state fallback. A divider follows pinned
/// regions only, which the section flags explicitly.
struct GitLogFilterListView<Row: GitLogFilterRow>: View {
    let sections: [GitLogFilterSection<Row>]
    let emptyText: LocalizedStringKey
    let isItemSelected: (Row) -> Bool
    let onSelect: (Row) -> Void

    var body: some View {
        if sections.allSatisfy({ $0.items.isEmpty }) {
            Text(emptyText)
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 72)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if let title = sectionHeaderTitle(section) {
                            sectionHeader(title, systemImage: section.systemImage)
                        }
                        ForEach(section.items) { item in
                            GitLogFilterRowView(
                                item: item,
                                isSelected: isItemSelected(item)
                            ) {
                                onSelect(item)
                            }
                        }
                        if section.isPinned && index < sections.count - 1 {
                            Rectangle()
                                .fill(LitheTheme.divider)
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
    }

    private func sectionHeaderTitle(_ section: GitLogFilterSection<Row>) -> Text? {
        if let titleKey = section.titleKey {
            return Text(titleKey)
        }
        if let title = section.title {
            return Text(verbatim: title)
        }
        return nil
    }

    private func sectionHeader(_ title: Text, systemImage: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5))
            }
            title
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 24)
    }
}

/// The IDEA-style branch filter popover: a compact first level (reset entry,
/// starred shortcuts, group rows) whose group rows open a bounded flyout
/// column, plus a flat filtered list once the user types a query. The menu is
/// injected as data so body re-evaluations never rebuild it.
struct GitLogBranchFilterPopover: View {
    let menu: GitLogBranchMenu
    let querySections: (String) -> [GitLogFilterSection<GitLogBranchFilterItem>]
    let isItemSelected: (GitLogBranchFilterItem) -> Bool
    let onSelect: (GitLogBranchFilterItem) -> Void

    @State private var searchQuery = ""
    @State private var expandedGroupID: String?

    var body: some View {
        VStack(spacing: 0) {
            GitLogFilterSearchBar(
                text: $searchQuery,
                placeholder: "Search branches",
                onSubmit: selectFirstMatch
            )
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            content
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: 460)
        .lithePopupChrome(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
    }

    // The popover opens at the compact width so the first frame has no dead
    // space; each width change is driven by an explicit user action (opening
    // a group or typing a query) rather than by layout surprises.
    private var popoverWidth: CGFloat {
        if !normalizedQuery.isEmpty { return 340 }
        return expandedGroup == nil ? 224 : 560
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var content: some View {
        if normalizedQuery.isEmpty {
            browseColumns
        } else {
            GitLogFilterListView(
                sections: querySections(normalizedQuery),
                emptyText: "No matching branches",
                isItemSelected: isItemSelected,
                onSelect: onSelect
            )
        }
    }

    private var browseColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            levelOneColumn
                .frame(width: 224)
            if let group = expandedGroup {
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                flyoutColumn(group)
                    .frame(width: 335)
            }
        }
    }

    private var expandedGroup: GitLogBranchGroup? {
        guard let expandedGroupID else { return nil }
        return menu.groups.first { $0.id == expandedGroupID }
    }

    private var levelOneColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                GitLogFilterRowView(
                    item: menu.reset,
                    isSelected: isItemSelected(menu.reset)
                ) {
                    onSelect(menu.reset)
                }
                ForEach(menu.starred) { item in
                    GitLogFilterRowView(
                        item: item,
                        isSelected: isItemSelected(item)
                    ) {
                        onSelect(item)
                    }
                }
                if !menu.starred.isEmpty {
                    Rectangle()
                        .fill(LitheTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 2)
                }
                ForEach(menu.groups) { group in
                    groupRow(group)
                }
                if menu.starred.isEmpty && menu.groups.isEmpty {
                    Text("No matching branches")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
            }
            .padding(6)
        }
    }

    private func groupRow(_ group: GitLogBranchGroup) -> some View {
        let isExpanded = expandedGroupID == group.id
        return Button {
            expandedGroupID = isExpanded ? nil : group.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 17)
                groupTitleText(group)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(isExpanded ? LitheTheme.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    @ViewBuilder
    private func groupTitleText(_ group: GitLogBranchGroup) -> some View {
        if let titleKey = group.titleKey {
            Text(titleKey)
        } else {
            Text(verbatim: group.title)
        }
    }

    private func flyoutColumn(_ group: GitLogBranchGroup) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(group.children) { child in
                    GitLogFilterRowView(
                        item: child,
                        isSelected: isItemSelected(child)
                    ) {
                        onSelect(child)
                    }
                }
            }
            .padding(6)
        }
    }

    private func selectFirstMatch() {
        guard !normalizedQuery.isEmpty else { return }
        guard let item = querySections(normalizedQuery).flatMap(\.items).first else { return }
        onSelect(item)
    }
}

/// A bounded, searchable, grouped dropdown for flat filters such as the Git
/// Log author filter. The popover keeps a fixed width and caps its height so
/// large lists scroll instead of covering the workbench.
struct GitLogFilterPopover<Row: GitLogFilterRow>: View {
    let sectionsForQuery: (String) -> [GitLogFilterSection<Row>]
    let searchPlaceholder: LocalizedStringKey
    let emptyText: LocalizedStringKey
    let isItemSelected: (Row) -> Bool
    let onSelect: (Row) -> Void

    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            GitLogFilterSearchBar(
                text: $searchQuery,
                placeholder: searchPlaceholder,
                onSubmit: selectFirstMatch
            )
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            GitLogFilterListView(
                sections: filteredSections,
                emptyText: emptyText,
                isItemSelected: isItemSelected,
                onSelect: onSelect
            )
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
        .lithePopupChrome(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
    }

    private var filteredSections: [GitLogFilterSection<Row>] {
        sectionsForQuery(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func selectFirstMatch() {
        guard let item = filteredSections.flatMap(\.items).first else { return }
        onSelect(item)
    }
}
