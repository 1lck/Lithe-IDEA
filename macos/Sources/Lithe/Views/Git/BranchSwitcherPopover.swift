import SwiftUI
import LitheGitModule

struct BranchSwitcherPopover: View {
    enum Metrics {
        // Community GitBranchesPopupBase: 300 + 8pt drag area + 2 × 2pt borders.
        static let minimumHeight: CGFloat = 312
        static let popupWidth = LitheDropdownMetrics.branchMinimumWidth
        static let searchBarHeight: CGFloat = 48
        static let branchRowHeight = LitheDropdownMetrics.rowHeight
        static let branchGroupHeaderHeight: CGFloat = 24
        static let branchListHeight: CGFloat = 240
        // Preserve the existing default height: five actions, two dividers and padding.
        static let scrollAreaHeight = branchListHeight + 5 * branchRowHeight + 22
    }

    @ObservedObject var feature: GitFeatureModel
    @Binding var isPresented: Bool
    let onCommit: () -> Void
    let onPush: (GitReference) -> Void
    let onDelete: (GitReference) -> Void
    let onNewBranch: (GitReference) -> Void
    let onCheckoutRevision: () -> Void
    let onManageBranches: () -> Void
    let onCompareWithWorkingTree: (GitReference) async -> Void
    let onCompareReferences: (GitReference, GitReference) async -> Void

    @State private var searchQuery = ""
    @State private var collapsedSections: Set<String> = []
    @State private var expandedRecentGroups: Set<String> = []
    @State private var expandedLocalGroups: Set<String> = []
    @State private var expandedRemoteGroups: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    actions
                    popupDivider
                    branchList
                }
            }
            .frame(minHeight: Metrics.branchRowHeight, idealHeight: Metrics.scrollAreaHeight, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: Metrics.popupWidth, maxWidth: .infinity, alignment: .leading)
        .task {
            expandedRecentGroups = Set(recentNamespaceGroups.map(\.id))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: LitheDropdownMetrics.iconSize,
                              preservesOriginalColors: true)
                LitheSearchTextField("Search for branches and actions", text: $searchQuery)
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/closeSmall.svg", size: LitheDropdownMetrics.iconSize,
                                      preservesOriginalColors: true)
                    }
                    .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4))
                    .padding(.leading, 1)
                    .accessibilityLabel("Clear search")
                }
            }
            // GitBranchesPopupBase passes Popup.BACKGROUND to the same search
            // wrapper used by Git Log; opening the tree doesn't focus its editor.
            .litheSearchField(isFocused: searchFocused, background: LitheTheme.popupBackground)
            .accessibilityIdentifier("branch-popup-search")

            Button(action: onManageBranches) {
                LitheIDEAIcon(resourcePath: "expui/vcs/fetch.svg", size: LitheDropdownMetrics.iconSize,
                              preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: 24, cornerRadius: LitheDropdownMetrics.rowCornerRadius))
            .help("Open Git branches")

            Button(action: onManageBranches) {
                LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: LitheDropdownMetrics.iconSize,
                              preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: 24, cornerRadius: LitheDropdownMetrics.rowCornerRadius))
            .help("Git branch options")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.searchBarHeight)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            // Keep the default command palette focused like IDEA. Fetch remains
            // discoverable through the search field without taking a permanent row.
            if !normalizedQuery.isEmpty && actionMatches("Fetch") {
                actionRow("Fetch", icon: "expui/vcs/fetch.svg", shortcut: nil) {
                    isPresented = false
                    Task { await feature.fetchGit() }
                }
                .disabled(feature.gitRepositoryRoot == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Update Project") {
                actionRow("Update Project…", icon: "expui/vcs/update.svg", shortcut: "⌘T") {
                    guard let current = feature.currentGitReference else { return }
                    isPresented = false
                    Task { await feature.updateCurrentBranch(current) }
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Commit") {
                actionRow("Commit…", icon: "expui/vcs/commit.svg", shortcut: "⌘K", action: onCommit)
            }

            if actionMatches("Push") {
                actionRow("Push…", icon: "expui/vcs/push.svg", shortcut: "⇧⌘K") {
                    guard let current = feature.currentGitReference else { return }
                    onPush(current)
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if searchQuery.isEmpty || actionMatches("New Branch") || actionMatches("Checkout Tag or Revision") {
                popupDivider.padding(.vertical, 5)
            }

            if actionMatches("New Branch") {
                actionRow("New Branch…", icon: "expui/general/add.svg", shortcut: "⌥⌘N") {
                    guard let current = feature.currentGitReference else { return }
                    onNewBranch(current)
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Checkout Tag or Revision") {
                actionRow("Checkout Tag or Revision…", icon: nil, shortcut: nil, action: onCheckoutRevision)
            }
        }
        .padding(.horizontal, LitheDropdownMetrics.popupPadding)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var branchList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if filteredReferences.isEmpty {
                Text(LocalizedStringKey(feature.isLoadingGitHistory ? "Loading branches…" : "No matching branches"))
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: Metrics.branchRowHeight)
            } else if normalizedQuery.isEmpty {
                if !recentReferences.isEmpty {
                    branchSectionHeader("Recent")
                    if !collapsedSections.contains("Recent") {
                        ForEach(recentReferenceRows.filter { localNamespace(for: $0.reference) == nil }) { row in
                            branchRow(row.reference, indented: true, presentation: .recent)
                        }
                        ForEach(recentNamespaceGroups) { group in
                            namespaceRow(group, expandedGroups: $expandedRecentGroups)
                            if expandedRecentGroups.contains(group.id) {
                                ForEach(group.rows) { row in
                                    branchRow(row.reference, indented: true, presentation: .namespaceChild)
                                }
                            }
                        }
                    }
                }
                groupedBranchRows
            } else {
                // Filtering searches every section without losing its expansion state.
                ForEach(searchResultRows) { row in
                    branchRow(row.reference, indented: false, presentation: .searchResult)
                }
            }
        }
        .padding(.horizontal, LitheDropdownMetrics.popupPadding)
        .padding(.vertical, LitheDropdownMetrics.popupPadding)
    }

    private func actionRow(
        _ title: String,
        icon: String?,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    LitheIDEAIcon(resourcePath: icon, size: LitheDropdownMetrics.iconSize,
                                  preservesOriginalColors: true)
                } else {
                    Color.clear.frame(width: LitheDropdownMetrics.iconSize, height: LitheDropdownMetrics.iconSize)
                }
                Text(LocalizedStringKey(title))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(LitheDropdownRowStyle())
    }

    @ViewBuilder
    private var groupedBranchRows: some View {
        if !localReferences.isEmpty {
            branchSectionHeader("Local")
            if !collapsedSections.contains("Local") {
                ForEach(localRootRows) { row in
                    branchRow(row.reference, indented: true, presentation: .grouped)
                }
                ForEach(localNamespaceGroups) { group in
                    namespaceRow(group, expandedGroups: $expandedLocalGroups)
                    if expandedLocalGroups.contains(group.id) {
                        ForEach(group.rows) { row in
                            branchRow(row.reference, indented: true, presentation: .namespaceChild)
                        }
                    }
                }
            }
        }
        if !remoteRootGroups.isEmpty {
            branchSectionHeader("Remote")
            if !collapsedSections.contains("Remote") {
                ForEach(remoteRootGroups) { group in
                    namespaceRow(group, expandedGroups: $expandedRemoteGroups)
                    if expandedRemoteGroups.contains(group.id) {
                        ForEach(remoteRows(in: group)) { row in
                            branchRow(row.reference, indented: true, presentation: .remoteChild)
                        }
                    }
                }
            }
        }
        if !tagRows.isEmpty {
            branchSectionHeader("Tags")
            if !collapsedSections.contains("Tags") {
                ForEach(tagRows) { row in
                    branchRow(row.reference, indented: true, presentation: .grouped)
                }
            }
        }
    }

    private func branchSectionHeader(_ title: String) -> some View {
        let collapsed = collapsedSections.contains(title)
        return Button {
            if collapsed { collapsedSections.remove(title) }
            else { collapsedSections.insert(title) }
        } label: {
            HStack(spacing: 7) {
                LitheIDEAIcon(resourcePath: collapsed ? "expui/general/chevronRight.svg" : "expui/general/chevronDown.svg",
                              size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true)
                Text(LocalizedStringKey(title))
                Spacer()
                if title == "Recent", feature.isLoadingGitHistory || feature.isPerformingBranchOperation {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(height: Metrics.branchGroupHeaderHeight)
        }
        .buttonStyle(LitheDropdownRowStyle())
        .accessibilityIdentifier("branch-section-" + title)
        .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
    }

    private func namespaceRow(_ group: BranchPopupGroup, expandedGroups: Binding<Set<String>>) -> some View {
        Button {
            if expandedGroups.wrappedValue.contains(group.id) {
                expandedGroups.wrappedValue.remove(group.id)
            } else {
                expandedGroups.wrappedValue.insert(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                LitheIDEAIcon(resourcePath: expandedGroups.wrappedValue.contains(group.id)
                              ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                              size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true)
                LitheIDEAIcon(resourcePath: "expui/nodes/folder.svg", size: LitheDropdownMetrics.iconSize,
                              preservesOriginalColors: true)
                Text(group.title)
                    .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.branchRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle())
    }

    /// A branch line. Clicking it opens the reference's action menu instead of
    /// checking out directly, matching IDEA: checkout is an explicit menu entry,
    /// so a stray click on the list can never switch the working tree.
    private func branchRow(
        _ reference: GitReference,
        indented: Bool,
        presentation: BranchRowPresentation
    ) -> some View {
        return BranchActionMenuRow(
            accessibilityTitle: branchRowAccessibilityTitle(reference),
            label: { expanded, highlighted in
                HStack(spacing: 8) {
                    LitheIDEAIcon(resourcePath: referenceIcon(reference), size: LitheDropdownMetrics.iconSize,
                                  preservesOriginalColors: true)
                    Text(verbatim: branchDisplayName(reference, presentation: presentation))
                        .font(LitheTheme.uiFont(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: expanded, vertical: true)
                        .layoutPriority(1)
                    if reference.kind == .local, reference.upstreamShortName != nil {
                        BranchPopupTrackingCounts(ahead: reference.ahead, behind: reference.behind)
                    }
                    Spacer(minLength: 10)
                    if let upstream = reference.upstreamShortName {
                        Text(verbatim: upstream)
                            .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
                            .foregroundStyle(highlighted ? LitheTheme.settingsSelectionText : Color(nsColor: .gray))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: expanded, vertical: true)
                    }
                    LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: LitheDropdownMetrics.iconSize,
                                  preservesOriginalColors: true)
                }
                .padding(.leading, branchRowLeadingPadding(indented: indented, presentation: presentation)
                         - LitheDropdownMetrics.itemHorizontalPadding)
                .padding(.trailing, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.branchRowHeight)
                .contentShape(Rectangle())
            },
            menuContent: { branchActionMenu(for: reference) }
        )
        .disabled(feature.isPerformingBranchOperation)
    }

    /// VoiceOver exposes both full names even when the visible labels are clipped.
    private func branchRowAccessibilityTitle(_ reference: GitReference) -> String {
        guard let upstream = reference.upstreamShortName else { return reference.shortName }
        return "\(reference.shortName) → \(upstream)"
            + (reference.behind > 0 ? " ↓\(reference.behind)" : "")
            + (reference.ahead > 0 ? " ↑\(reference.ahead)" : "")
    }

    /// The per-reference action list, ordered like IDEA's branch menu: creation
    /// and comparison first, then checkout and integration, then destructive
    /// entries last.
    @LitheMenuItemsBuilder
    private func branchActionMenu(for reference: GitReference) -> [LitheContextMenuItem] {
        LitheContextMenuItem.action("New Branch from '\(reference.shortName)'…") {
            dismissAndRun { onNewBranch(reference) }
        }

        LitheContextMenuItem.action("Show Diff with Working Tree") {
            dismissAndRun { Task { await onCompareWithWorkingTree(reference) } }
        }

        if let current = feature.currentGitReference, current.id != reference.id {
            LitheContextMenuItem.action("Compare with Current Branch") {
                dismissAndRun { Task { await onCompareReferences(reference, current) } }
            }
        }

        if !reference.isCurrent {
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Checkout") {
                dismissAndRun { Task { await feature.checkoutReference(reference) } }
            }
        }

        if reference.kind == .local {
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Update") {
                dismissAndRun { Task { await feature.updateCurrentBranch(reference) } }
            }
            .disabled(!reference.isCurrent)

            LitheContextMenuItem.action("Push…") {
                dismissAndRun { onPush(reference) }
            }
        }

        if reference.kind == .local, !reference.isCurrent {
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Delete", role: .destructive) {
                dismissAndRun { onDelete(reference) }
            }
        }
    }

    /// Closes the popover before running a branch action so the action's own
    /// sheet or dialog is not presented behind a popover that is about to go away.
    private func dismissAndRun(_ action: @escaping () -> Void) {
        isPresented = false
        action()
    }

    private var recentReferences: [GitReference] {
        guard normalizedQuery.isEmpty else { return [] }
        return feature.recentGitReferences
    }

    private var recentReferenceRows: [BranchPopupRow] {
        recentReferences.map { reference in
            BranchPopupRow(
                id: "recent:\(reference.id)",
                reference: reference
            )
        }
    }

    private var filteredReferences: [GitReference] {
        let query = normalizedQuery
        guard !query.isEmpty else { return feature.gitReferences }
        return feature.gitReferences.filter { reference in
            reference.shortName.localizedCaseInsensitiveContains(query) ||
                reference.upstreamShortName?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var searchResultRows: [BranchPopupRow] {
        sortedReferences(filteredReferences).map { reference in
            BranchPopupRow(id: "search:\(reference.id)", reference: reference)
        }
    }

    private var localReferences: [GitReference] {
        sortedReferences(filteredReferences.filter { $0.kind == .local })
    }

    private var localRootRows: [BranchPopupRow] {
        localReferences
            .filter { localNamespace(for: $0) == nil }
            .map { reference in
                BranchPopupRow(id: "local-root:\(reference.id)", reference: reference)
            }
    }

    private var localNamespaceGroups: [BranchPopupGroup] { namespaceGroups(in: localReferences) }

    private var recentNamespaceGroups: [BranchPopupGroup] { namespaceGroups(in: recentReferences) }

    private func namespaceGroups(in references: [GitReference]) -> [BranchPopupGroup] {
        let grouped = Dictionary(grouping: references.compactMap { reference -> (String, GitReference)? in
            guard let namespace = localNamespace(for: reference) else { return nil }
            return (namespace, reference)
        }) { $0.0 }

        return grouped.map { namespace, entries in
            return BranchPopupGroup(
                title: namespace,
                kind: .local,
                references: sortedReferences(entries.map { $0.1 })
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var remoteRootGroups: [BranchPopupGroup] {
        let remoteReferences = filteredReferences.filter { $0.kind == .remote }
        let grouped = Dictionary(grouping: remoteReferences) { reference in
            reference.shortName.split(separator: "/").first.map(String.init) ?? reference.shortName
        }

        return grouped.map { remoteName, references in
            return BranchPopupGroup(
                title: remoteName,
                kind: .remote,
                references: sortedReferences(references)
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func remoteRows(in group: BranchPopupGroup) -> [BranchPopupRow] {
        group.rows.filter { $0.reference.shortName != group.title }
    }

    private var tagRows: [BranchPopupRow] {
        sortedReferences(filteredReferences.filter { $0.kind == .tag }).map { reference in
            BranchPopupRow(id: "tag:\(reference.id)", reference: reference)
        }
    }

    private func sortedReferences(_ references: [GitReference]) -> [GitReference] {
        references.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
        }
    }

    private func localNamespace(for reference: GitReference) -> String? {
        let components = reference.shortName.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private func branchRowLeadingPadding(
        indented: Bool,
        presentation: BranchRowPresentation
    ) -> CGFloat {
        if presentation == .namespaceChild || presentation == .remoteChild { return 48 }
        return indented ? 28 : 10
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actionMatches(_ title: String) -> Bool {
        normalizedQuery.isEmpty || title.localizedCaseInsensitiveContains(normalizedQuery)
    }

    private var popupDivider: some View {
        Rectangle()
            .fill(LitheTheme.divider.opacity(0.55))
            .frame(height: 1)
    }

    private func referenceIcon(_ reference: GitReference) -> String {
        if reference.isCurrent { return "dvcs/currentBranchLabel.svg" }
        return reference.kind == .tag ? "dvcs/branchLabel.svg" : "expui/general/vcs.svg"
    }

    private func branchDisplayName(
        _ reference: GitReference,
        presentation: BranchRowPresentation
    ) -> String {
        switch presentation {
        case .namespaceChild:
            return reference.shortName.split(separator: "/").last.map(String.init) ?? reference.shortName
        case .remoteChild:
            let components = reference.shortName.split(separator: "/")
            guard components.count > 1 else { return reference.shortName }
            return components.dropFirst().joined(separator: "/")
        case .recent, .grouped, .searchResult:
            return reference.shortName
        }
    }
}

/// A branch row opens its actions in the shared product dropdown.
private struct BranchActionMenuRow<Label: View>: View {
    @State private var isPresented = false
    let accessibilityTitle: String
    @ViewBuilder let label: (Bool, Bool) -> Label
    @LitheMenuItemsBuilder let menuContent: () -> [LitheContextMenuItem]

    var body: some View {
        BranchPopupRowView(isPresented: isPresented, accessibilityTitle: accessibilityTitle,
                       onPress: { isPresented.toggle() }, label: label)
            .overlay {
                LitheDropdownPopover(opensToSide: true, isPresented: $isPresented, items: menuContent()) { EmptyView() }
            }
            .frame(height: LitheDropdownMetrics.rowHeight)
    }
}

private enum BranchRowPresentation {
    case recent
    case grouped
    case namespaceChild
    case remoteChild
    case searchResult
}

private struct BranchPopupGroup: Identifiable {
    let title: String
    let kind: GitReferenceKind
    let references: [GitReference]

    var id: String { "\(kind.rawValue):\(title)" }

    var rows: [BranchPopupRow] {
        references.map { reference in
            BranchPopupRow(
                id: "group:\(id):\(reference.id)",
                reference: reference
            )
        }
    }
}

private struct BranchPopupRow: Identifiable {
    let id: String
    let reference: GitReference
}

struct TopBarNewBranchDialog: View {
    @Environment(\.dismiss) private var dismiss
    let reference: GitReference
    let onSubmit: (String, Bool) -> Void

    @State private var branchName = ""
    @State private var checkout = true
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Branch")
                .font(LitheTheme.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Create from '\(reference.shortName)'.")
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            Toggle("Checkout branch after creation", isOn: $checkout)
                .toggleStyle(.checkbox)
                .lithePointer()
                .font(LitheTheme.uiFont(size: 12.5))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button("Create", action: submit)
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(LitheTheme.raised)
        .onAppear { fieldFocused = true }
    }

    private var trimmedName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName, checkout)
        dismiss()
    }
}

struct CheckoutRevisionDialog: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String) -> Void

    @State private var revision = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Checkout Tag or Revision")
                .font(LitheTheme.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Enter a tag name, branch name, commit hash, or other Git revision.")
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Tag or revision", text: $revision)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            Text("The repository will be opened in detached HEAD state.")
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.warning)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button("Checkout", action: submit)
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedRevision.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
        .background(LitheTheme.raised)
        .onAppear { fieldFocused = true }
    }

    private var trimmedRevision: String {
        revision.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedRevision.isEmpty else { return }
        onSubmit(trimmedRevision)
        dismiss()
    }
}
