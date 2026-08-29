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
    var rowDetail: String? { get }
    var rowSystemImage: String { get }
    /// Starred rows use the accent color for their icon, mirroring IDEA's
    /// starred branch shortcuts.
    var rowIsStarred: Bool { get }
}

extension GitLogFilterRow {
    var rowIsStarred: Bool { false }
}

/// A titled group of rows inside a flat Git Log filter popover. A `nil` title
/// marks an ungrouped region such as the pinned reset entries.
struct GitLogFilterSection<Row: GitLogFilterRow>: Identifiable {
    let id: String
    let title: String?
    let systemImage: String?
    let items: [Row]
}

/// A branch filter row: the pinned "All Branches" reset entry, a starred
/// shortcut, or a concrete reference inside a group flyout. `title` is the
/// display name computed at section-build time (flyouts show full names).
struct GitLogBranchFilterItem: GitLogFilterRow, Hashable {
    let reference: GitReference?
    let title: String
    let detail: String?
    let isStarred: Bool

    init(reference: GitReference?, title: String, detail: String?, isStarred: Bool = false) {
        self.reference = reference
        self.title = title
        self.detail = detail
        self.isStarred = isStarred
    }

    var id: String { reference?.fullName ?? "all-branches" }
    var rowTitle: String { title }
    var rowDetail: String? { detail }
    var rowIsStarred: Bool { isStarred }

    var rowSystemImage: String {
        guard let reference else { return "point.3.connected.trianglepath.dotted" }
        if reference.isCurrent || isStarred { return "star.fill" }
        switch reference.kind {
        case .local: return "point.3.connected.trianglepath.dotted"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }

    static var allBranches: GitLogBranchFilterItem {
        GitLogBranchFilterItem(reference: nil, title: "All Branches", detail: nil)
    }
}

/// An author filter row: a pinned reset entry, the current user, or a
/// concrete commit author.
struct GitLogAuthorFilterItem: GitLogFilterRow, Hashable {
    enum Kind: Hashable {
        case allUsers
        case currentUser
        case author(name: String, email: String)
    }

    let kind: Kind
    let title: String
    let detail: String?

    var id: String {
        switch kind {
        case .allUsers: return "all-users"
        case .currentUser: return "current-user"
        case .author(let name, let email): return "\(name.lowercased())|\(email.lowercased())"
        }
    }

    var rowTitle: String { title }
    var rowDetail: String? { detail }

    var rowSystemImage: String {
        switch kind {
        case .allUsers: return "person.2"
        case .currentUser: return "person.fill"
        case .author: return "person"
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
}

/// A first-level group whose children open in the branch popover's flyout
/// column, mirroring IDEA's `origin/…` and `本地` submenu rows.
struct GitLogBranchGroup: Identifiable {
    let id: String
    let title: String
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

/// Pure builders for the Git Log filter popovers. Deterministic and
/// side-effect free so large repositories produce stable, testable lists.
enum GitLogFilterList {
    /// Builds the browse-mode branch menu: starred shortcuts for the current
    /// branch and its upstream, then non-empty groups ordered Local,
    /// remotes by name (`origin/…`), and Tags. Flyout children keep full
    /// short names and sort current-branch first.
    static func branchMenu(references: [GitReference]) -> GitLogBranchMenu {
        var starred: [GitLogBranchFilterItem] = []
        if let current = references.first(where: { $0.isCurrent }) {
            starred.append(GitLogBranchFilterItem(
                reference: current,
                title: current.shortName,
                detail: nil,
                isStarred: true
            ))
            if let upstreamName = current.upstreamShortName,
               let upstream = references.first(where: { $0.kind == .remote && $0.shortName == upstreamName }) {
                starred.append(GitLogBranchFilterItem(
                    reference: upstream,
                    title: upstream.shortName,
                    detail: nil,
                    isStarred: true
                ))
            }
        }

        var groups: [GitLogBranchGroup] = []
        let locals = references.filter { $0.kind == .local }
        if !locals.isEmpty {
            groups.append(GitLogBranchGroup(
                id: "local",
                title: "Local",
                systemImage: "arrow.triangle.branch",
                children: locals
                    .sorted { lhs, rhs in
                        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                        return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
                    }
                    .map { reference in
                        GitLogBranchFilterItem(
                            reference: reference,
                            title: reference.shortName,
                            detail: reference.upstreamShortName
                        )
                    }
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
            let groupReferences = remotesByName[remoteName] ?? []
            let children = groupReferences
                .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
                .map { reference in
                    GitLogBranchFilterItem(
                        reference: reference,
                        title: reference.shortName,
                        detail: nil
                    )
                }
            return GitLogBranchGroup(
                id: "remote:\(remoteName)",
                title: "\(remoteName)/…",
                systemImage: "cloud",
                children: children
            )
        }
        groups.append(contentsOf: remoteGroups)

        let tags = references.filter { $0.kind == .tag }
        if !tags.isEmpty {
            groups.append(GitLogBranchGroup(
                id: "tags",
                title: "Tags",
                systemImage: "tag",
                children: tags
                    .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
                    .map { reference in
                        GitLogBranchFilterItem(
                            reference: reference,
                            title: reference.shortName,
                            detail: nil
                        )
                    }
            ))
        }

        return GitLogBranchMenu(
            reset: .allBranches,
            starred: starred,
            groups: groups
        )
    }

    /// Builds flat branch sections for the popover's type-to-search mode: the
    /// pinned "All Branches" reset entry followed by local namespaces,
    /// remotes, and tags grouped like the branch switcher popover. The query
    /// matches short names and upstreams case-insensitively; an empty query
    /// matches everything, including the pinned entry.
    static func branchSections(
        references: [GitReference],
        query: String
    ) -> [GitLogFilterSection<GitLogBranchFilterItem>] {
        var sections: [GitLogFilterSection<GitLogBranchFilterItem>] = []
        // An empty search string never matches `localizedCaseInsensitiveContains`,
        // so treat it as "match everything" explicitly.
        if query.isEmpty || "All Branches".localizedCaseInsensitiveContains(query) {
            sections.append(GitLogFilterSection(
                id: "all-branches",
                title: nil,
                systemImage: nil,
                items: [.allBranches]
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
                systemImage: groupSystemImage(group.kind),
                items: group.references
                    .sorted { lhs, rhs in
                        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                        return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
                    }
                    .map { reference in
                        GitLogBranchFilterItem(
                            reference: reference,
                            title: displayTitle(for: reference, groupTitle: group.title),
                            detail: reference.upstreamShortName ?? kindLabel(reference.kind)
                        )
                    }
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
        if query.isEmpty || "All Users".localizedCaseInsensitiveContains(query) {
            pinned.append(GitLogAuthorFilterItem(kind: .allUsers, title: "All Users", detail: nil))
        }
        if query.isEmpty || "Me".localizedCaseInsensitiveContains(query) {
            pinned.append(GitLogAuthorFilterItem(kind: .currentUser, title: "Me", detail: nil))
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
            GitLogAuthorFilterItem(
                kind: .author(name: author.name, email: author.email),
                title: author.name,
                detail: author.email
            )
        }

        var sections: [GitLogFilterSection<GitLogAuthorFilterItem>] = []
        if !pinned.isEmpty {
            sections.append(GitLogFilterSection(
                id: "pinned",
                title: nil,
                systemImage: nil,
                items: pinned
            ))
        }
        if !sorted.isEmpty {
            sections.append(GitLogFilterSection(
                id: "authors",
                title: nil,
                systemImage: nil,
                items: sorted
            ))
        }
        return sections
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

    private static func kindLabel(_ kind: GitReferenceKind) -> String? {
        switch kind {
        case .local: return nil
        case .remote: return "Remote"
        case .tag: return "Tag"
        }
    }

    private static func displayTitle(for reference: GitReference, groupTitle: String) -> String {
        guard reference.kind == .local, !groupTitle.isEmpty else { return reference.shortName }
        return reference.shortName.split(separator: "/").last.map(String.init) ?? reference.shortName
    }
}

/// Shared search field for Git Log filter popovers; focuses itself on appear
/// so typing filters immediately.
struct GitLogFilterSearchBar: View {
    @Binding var text: String
    let placeholder: String
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
                Text(item.rowTitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let detail = item.rowDetail {
                    Text(detail)
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
}

/// Shared grouped-list body for flat filter popovers: section headers plus
/// row rendering with an empty-state fallback.
struct GitLogFilterListView<Row: GitLogFilterRow>: View {
    let sections: [GitLogFilterSection<Row>]
    let emptyText: String
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
                        if let title = section.title {
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
                        // Untitled regions such as pinned reset rows end with a
                        // divider before the grouped content below.
                        if section.title == nil && index < sections.count - 1 {
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

    private func sectionHeader(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5))
            }
            Text(LocalizedStringKey(title))
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
/// column, plus a flat filtered list once the user types a query.
struct GitLogBranchFilterPopover: View {
    let menuBuilder: () -> GitLogBranchMenu
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
        .frame(width: normalizedQuery.isEmpty ? 560 : 340)
        .frame(maxHeight: 460)
        .lithePopupChrome(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var menu: GitLogBranchMenu {
        menuBuilder()
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
        HStack(spacing: 0) {
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
                Text(LocalizedStringKey(group.title))
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
    let searchPlaceholder: String
    let emptyText: String
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
