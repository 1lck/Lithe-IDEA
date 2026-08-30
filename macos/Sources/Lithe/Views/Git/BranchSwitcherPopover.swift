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

    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    let onCommit: () -> Void
    let onPush: (GitReference) -> Void
    let onNewBranch: (GitReference) -> Void
    let onCheckoutRevision: () -> Void
    let onManageBranches: () -> Void

    @State private var searchQuery = ""
    @State private var expandedLocalGroups: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            actions
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            branchList
        }
        .frame(width: Metrics.popupWidth, alignment: .leading)
        .lithePopupChrome(cornerRadius: LitheTheme.Metrics.popupCornerRadius)
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
            .help("Open Git branches")

            Button(action: onManageBranches) {
                LitheSystemIcon(systemImage: "gearshape")
            }
            .litheIconButton()
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
                    Task { await model.fetchGit() }
                }
                .disabled(model.gitRepositoryRoot == nil || model.isPerformingBranchOperation)
            }

            if actionMatches("Update Project") {
                actionRow("Update Project…", icon: "arrow.down.left", shortcut: "⌘T") {
                    guard let current = model.currentGitReference else { return }
                    isPresented = false
                    Task { await model.updateCurrentBranch(current) }
                }
                .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
            }

            if actionMatches("Commit") {
                actionRow("Commit…", icon: "slider.horizontal.3", shortcut: "⌘K", action: onCommit)
            }

            if actionMatches("Push") {
                actionRow("Push…", icon: "arrow.up.right", shortcut: "⇧⌘K") {
                    guard let current = model.currentGitReference else { return }
                    onPush(current)
                }
                .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
            }

            if searchQuery.isEmpty || actionMatches("New Branch") || actionMatches("Checkout Tag or Revision") {
                Rectangle().fill(LitheTheme.divider).frame(height: 1).padding(.vertical, 5)
            }

            if actionMatches("New Branch") {
                actionRow("New Branch…", icon: "plus", shortcut: "⌥⌘N") {
                    guard let current = model.currentGitReference else { return }
                    onNewBranch(current)
                }
                .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
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
                if model.isLoadingGitHistory || model.isPerformingBranchOperation {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: Metrics.branchGroupHeaderHeight)

            Group {
                if filteredReferences.isEmpty {
                    Text(model.isLoadingGitHistory ? "Loading branches…" : "No matching branches")
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
                                    Rectangle()
                                        .fill(LitheTheme.divider)
                                        .frame(height: 1)
                                        .padding(.vertical, 6)
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

        ForEach(nonLocalGroups) { group in
            branchSectionHeader(group.title)
            ForEach(group.rows) { row in
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

    private func branchRow(
        _ reference: GitReference,
        indented: Bool,
        presentation: BranchRowPresentation
    ) -> some View {
        let highlightsCurrent = presentation == .recent && reference.isCurrent

        return Button {
            guard !reference.isCurrent else { return }
            isPresented = false
            Task { await model.checkoutReference(reference) }
        } label: {
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
                if !reference.isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .padding(.leading, branchRowLeadingPadding(indented: indented, presentation: presentation))
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.branchRowHeight)
            .background(highlightsCurrent ? LitheTheme.subtleSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .disabled(model.isPerformingBranchOperation)
    }

    private var recentReferences: [GitReference] {
        guard normalizedQuery.isEmpty else { return [] }
        return Array(model.gitReferences.prefix(2))
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
        guard !query.isEmpty else { return model.gitReferences }
        return model.gitReferences.filter { reference in
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

    private var nonLocalGroups: [BranchPopupGroup] {
        [GitReferenceKind.remote, .tag].compactMap { kind in
            let references = sortedReferences(filteredReferences.filter { $0.kind == kind })
            guard !references.isEmpty else { return nil }
            return BranchPopupGroup(
                title: kind == .remote ? "Remote" : "Tags",
                kind: kind,
                references: references
            )
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
        if presentation == .namespaceChild { return 48 }
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
        guard presentation == .namespaceChild else { return reference.shortName }
        return reference.shortName.split(separator: "/").last.map(String.init) ?? reference.shortName
    }
}

private enum BranchRowPresentation {
    case recent
    case grouped
    case namespaceChild
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
