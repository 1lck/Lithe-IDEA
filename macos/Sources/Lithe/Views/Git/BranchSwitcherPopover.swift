import SwiftUI
import LitheGitModule

struct BranchSwitcherPopover: View {
    enum Metrics {
        static let popupWidth: CGFloat = 375
        static let searchBarHeight: CGFloat = 56
        static let actionRowHeight: CGFloat = 30
        static let branchRowHeight: CGFloat = 28
        static let branchGroupHeaderHeight: CGFloat = 24
        static let branchListHeight: CGFloat = 240
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
    @State private var expandedLocalGroups: Set<String> = []
    @State private var expandedRemoteGroups: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            popupDivider
            actions
            popupDivider
            branchList
        }
        .frame(width: Metrics.popupWidth, alignment: .leading)
        .litheRoundedControlBackground(
            LitheTheme.popupBackground,
            cornerRadius: LitheTheme.Metrics.popupCornerRadius
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                LitheSystemIcon(systemImage: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Search for branches and actions", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(LitheTheme.popupBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(LitheTheme.panelBorder, lineWidth: 1)
                    }
            )

            Button(action: onManageBranches) {
                LitheSystemIcon(systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Open Git branches")

            Button(action: onManageBranches) {
                LitheSystemIcon(systemImage: "gearshape")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Git branch options")
        }
        .padding(.leading, 13)
        .padding(.trailing, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.searchBarHeight)
        .background {
            topRoundedSectionBackground(LitheTheme.toolHeader)
        }
    }

    private var actions: some View {
        VStack(spacing: 1) {
            // Keep the default command palette focused like IDEA. Fetch remains
            // discoverable through the search field without taking a permanent row.
            if !normalizedQuery.isEmpty && actionMatches("Fetch") {
                actionRow("Fetch", icon: "arrow.down.to.line", shortcut: nil) {
                    isPresented = false
                    Task { await feature.fetchGit() }
                }
                .disabled(feature.gitRepositoryRoot == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Update Project") {
                actionRow("Update Project…", icon: "arrow.down.left", shortcut: "⌘T") {
                    guard let current = feature.currentGitReference else { return }
                    isPresented = false
                    Task { await feature.updateCurrentBranch(current) }
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Commit") {
                actionRow("Commit…", icon: "slider.horizontal.3", shortcut: "⌘K", action: onCommit)
            }

            if actionMatches("Push") {
                actionRow("Push…", icon: "arrow.up.right", shortcut: "⇧⌘K") {
                    guard let current = feature.currentGitReference else { return }
                    onPush(current)
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if searchQuery.isEmpty || actionMatches("New Branch") || actionMatches("Checkout Tag or Revision") {
                popupDivider.padding(.vertical, 5)
            }

            if actionMatches("New Branch") {
                actionRow("New Branch…", icon: "plus", shortcut: "⌥⌘N") {
                    guard let current = feature.currentGitReference else { return }
                    onNewBranch(current)
                }
                .disabled(feature.currentGitReference == nil || feature.isPerformingBranchOperation)
            }

            if actionMatches("Checkout Tag or Revision") {
                actionRow("Checkout Tag or Revision…", icon: "number", shortcut: nil, action: onCheckoutRevision)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var branchList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                Text(searchQuery.isEmpty ? "Recent" : "Branches")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if feature.isLoadingGitHistory || feature.isPerformingBranchOperation {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: Metrics.branchGroupHeaderHeight)

            Group {
                if filteredReferences.isEmpty {
                    Text(feature.isLoadingGitHistory ? "Loading branches…" : "No matching branches")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if searchQuery.isEmpty {
                                ForEach(recentReferenceRows) { row in
                                    branchRow(row.reference, indented: false, presentation: .recent)
                                }

                                if !recentReferences.isEmpty && !filteredReferences.isEmpty {
                                    popupDivider.padding(.vertical, 6)
                                }

                                groupedBranchRows
                            } else {
                                ForEach(searchResultRows) { row in
                                    branchRow(row.reference, indented: false, presentation: .searchResult)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(height: Metrics.branchListHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            bottomRoundedSectionBackground(LitheTheme.sidebar)
        }
    }

    private func actionRow(
        _ title: String,
        icon: String,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 18)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.actionRowHeight)
            .litheRowHover(
                cornerRadius: 6,
                hoverBackground: LitheTheme.subtleSelection
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    @ViewBuilder
    private var groupedBranchRows: some View {
        if !localReferences.isEmpty {
            branchSectionHeader("Local")

            ForEach(localRootRows) { row in
                branchRow(row.reference, indented: true, presentation: .grouped)
            }

            ForEach(localNamespaceGroups) { group in
                localNamespaceRow(group)
                if expandedLocalGroups.contains(group.id) {
                    ForEach(group.rows) { row in
                        branchRow(row.reference, indented: true, presentation: .namespaceChild)
                    }
                }
            }
        }

        if !remoteRootGroups.isEmpty {
            branchSectionHeader("Remote")

            ForEach(remoteRootGroups) { group in
                remoteRootRow(group)
                if expandedRemoteGroups.contains(group.id) {
                    ForEach(remoteRows(in: group)) { row in
                        branchRow(row.reference, indented: true, presentation: .remoteChild)
                    }
                }
            }
        }

        if !tagRows.isEmpty {
            branchSectionHeader("Tags")
            ForEach(tagRows) { row in
                branchRow(row.reference, indented: true, presentation: .grouped)
            }
        }
    }

    private func branchSectionHeader(_ title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: Metrics.branchGroupHeaderHeight)
    }

    private func localNamespaceRow(_ group: BranchPopupGroup) -> some View {
        return Button {
            if expandedLocalGroups.contains(group.id) {
                expandedLocalGroups.remove(group.id)
            } else {
                expandedLocalGroups.insert(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedLocalGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 12)
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 17)
                Text(group.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.branchRowHeight)
            .contentShape(Rectangle())
            .litheRowHover(cornerRadius: 5, hoverBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func remoteRootRow(_ group: BranchPopupGroup) -> some View {
        return Button {
            if expandedRemoteGroups.contains(group.id) {
                expandedRemoteGroups.remove(group.id)
            } else {
                expandedRemoteGroups.insert(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedRemoteGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 12)
                Image(systemName: "cloud")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 17)
                Text(group.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.branchRowHeight)
            .contentShape(Rectangle())
            .litheRowHover(cornerRadius: 5, hoverBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    /// A branch line. Clicking it opens the reference's action menu instead of
    /// checking out directly, matching IDEA: checkout is an explicit menu entry,
    /// so a stray click on the list can never switch the working tree.
    private func branchRow(
        _ reference: GitReference,
        indented: Bool,
        presentation: BranchRowPresentation
    ) -> some View {
        let highlightsCurrent = presentation == .recent && reference.isCurrent

        return BranchActionMenuRow(
            label: {
                HStack(spacing: 8) {
                    Image(systemName: referenceIcon(reference, marksCurrent: presentation == .recent))
                        .font(.system(size: 11.5))
                        .foregroundStyle(highlightsCurrent ? LitheTheme.warning : LitheTheme.secondaryText)
                        .frame(width: 17)
                    Text(branchDisplayName(reference, presentation: presentation))
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    if let upstream = reference.upstreamShortName {
                        Text(upstream)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.leading, branchRowLeadingPadding(indented: indented, presentation: presentation))
                .padding(.trailing, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.branchRowHeight)
                .background(highlightsCurrent ? LitheTheme.subtleSelection : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                // Branch and upstream names are truncated to keep the row width
                // fixed, so the untruncated pair is only reachable on hover.
                .help(branchRowTooltip(reference))
            },
            menuContent: { branchActionMenu(for: reference) }
        )
        .disabled(feature.isPerformingBranchOperation)
    }

    /// The full branch name, plus its upstream when tracked, for rows whose text
    /// the fixed popup width truncates.
    private func branchRowTooltip(_ reference: GitReference) -> String {
        guard let upstream = reference.upstreamShortName else { return reference.shortName }
        return "\(reference.shortName) → \(upstream)"
    }

    /// The per-reference action list, ordered like IDEA's branch menu: creation
    /// and comparison first, then checkout and integration, then destructive
    /// entries last.
    @ViewBuilder
    private func branchActionMenu(for reference: GitReference) -> some View {
        Button("New Branch from '\(reference.shortName)'…") {
            dismissAndRun { onNewBranch(reference) }
        }

        Button("Show Diff with Working Tree") {
            dismissAndRun { Task { await onCompareWithWorkingTree(reference) } }
        }

        if let current = feature.currentGitReference, current.id != reference.id {
            Button("Compare with Current Branch") {
                dismissAndRun { Task { await onCompareReferences(reference, current) } }
            }
        }

        if !reference.isCurrent {
            Divider()

            Button("Checkout") {
                dismissAndRun { Task { await feature.checkoutReference(reference) } }
            }
        }

        if reference.kind == .local {
            Divider()

            Button("Update") {
                dismissAndRun { Task { await feature.updateCurrentBranch(reference) } }
            }
            .disabled(!reference.isCurrent)

            Button("Push…") {
                dismissAndRun { onPush(reference) }
            }
        }

        if reference.kind == .local, !reference.isCurrent {
            Divider()

            Button("Delete", role: .destructive) {
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

    private var localNamespaceGroups: [BranchPopupGroup] {
        let grouped = Dictionary(grouping: localReferences.compactMap { reference -> (String, GitReference)? in
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

    private func topRoundedSectionBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
            .fill(color)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(color)
                    .frame(height: LitheTheme.Metrics.popupCornerRadius)
            }
    }

    private var popupDivider: some View {
        Rectangle()
            .fill(LitheTheme.divider.opacity(0.55))
            .frame(height: 1)
    }

    private func bottomRoundedSectionBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
            .fill(color)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(color)
                    .frame(height: LitheTheme.Metrics.popupCornerRadius)
            }
    }

    private func referenceIcon(_ reference: GitReference, marksCurrent: Bool) -> String {
        if marksCurrent, reference.isCurrent { return "star" }
        switch reference.kind {
        case .local: return "point.3.connected.trianglepath.dotted"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
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

/// A branch row that surfaces its actions through a native pop-up menu rather
/// than a direct checkout.
///
/// Using `SwiftUI.Menu` with `.menuStyle(.borderlessButton)` produces a native
/// NSMenu, which works correctly inside the outer popover, positions itself to
/// avoid screen edges, and provides the hover-safety path that IDEA exposes:
/// once any row's menu is open, moving the cursor to another row opens that
/// menu immediately without a click.
private struct BranchActionMenuRow<Label: View, MenuContent: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        SwiftUI.Menu {
            menuContent()
        } label: {
            label()
                .background(isHovering ? LitheTheme.subtleSelection : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Constrain to the list width so the menu button does not stretch.
        .fixedSize(horizontal: false, vertical: true)
        .lithePointer()
        .onHover { isHovering = $0 }
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Create from '\(reference.shortName)'.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            Toggle("Checkout branch after creation", isOn: $checkout)
                .toggleStyle(.checkbox)
                .lithePointer()
                .font(.system(size: 12.5))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Enter a tag name, branch name, commit hash, or other Git revision.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Tag or revision", text: $revision)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            Text("The repository will be opened in detached HEAD state.")
                .font(.system(size: 10.5))
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
