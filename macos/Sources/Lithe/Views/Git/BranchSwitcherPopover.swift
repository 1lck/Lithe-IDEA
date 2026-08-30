import SwiftUI
import LitheGitModule

struct BranchSwitcherPopover: View {
    private enum Metrics {
        static let popupWidth: CGFloat = 375
        static let searchBarHeight: CGFloat = 56
        static let actionRowHeight: CGFloat = 30
        static let branchRowHeight: CGFloat = 30
        static let branchGroupHeaderHeight: CGFloat = 24
        static let minimumBranchListHeight: CGFloat = 160
        static let maximumBranchListHeight: CGFloat = 240
    }

    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    let onCommit: () -> Void
    let onPush: (GitReference) -> Void
    let onNewBranch: (GitReference) -> Void
    let onCheckoutRevision: () -> Void
    let onManageBranches: () -> Void

    @State private var searchQuery = ""
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
        .background(LitheTheme.toolHeader)
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

            if filteredReferences.isEmpty {
                Text(model.isLoadingGitHistory ? "Loading branches…" : "No matching branches")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searchQuery.isEmpty {
                            ForEach(recentReferences) { reference in
                                branchRow(reference, indented: false)
                            }

                            if !recentReferences.isEmpty && !branchGroups.isEmpty {
                                Rectangle()
                                    .fill(LitheTheme.divider)
                                    .frame(height: 1)
                                    .padding(.vertical, 6)
                            }
                        }

                        ForEach(branchGroups) { group in
                            if !group.title.isEmpty {
                                HStack(spacing: 7) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(LocalizedStringKey(group.title))
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding(.horizontal, 14)
                                .frame(height: Metrics.branchGroupHeaderHeight)
                            }

                            ForEach(group.references) { reference in
                                branchRow(reference, indented: !group.title.isEmpty)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(minHeight: Metrics.minimumBranchListHeight, maxHeight: Metrics.maximumBranchListHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.sidebar)
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

    private func branchRow(_ reference: GitReference, indented: Bool) -> some View {
        Button {
            isPresented = false
            Task { await model.checkoutReference(reference) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: referenceIcon(reference))
                    .font(.system(size: 11.5))
                    .foregroundStyle(reference.isCurrent ? LitheTheme.warning : LitheTheme.secondaryText)
                    .frame(width: 17)
                Text(branchDisplayName(reference, insideGroup: indented))
                    .font(.system(size: 12.5, weight: reference.isCurrent ? .semibold : .regular))
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
            .padding(.leading, indented ? 28 : 10)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.branchRowHeight)
            .background(reference.isCurrent ? LitheTheme.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .disabled(reference.isCurrent || model.isPerformingBranchOperation)
    }

    private var recentReferences: [GitReference] {
        guard normalizedQuery.isEmpty else { return [] }
        return Array(model.gitReferences.prefix(3))
    }

    private var filteredReferences: [GitReference] {
        let query = normalizedQuery
        guard !query.isEmpty else { return model.gitReferences }
        return model.gitReferences.filter { reference in
            reference.shortName.localizedCaseInsensitiveContains(query) ||
                reference.upstreamShortName?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var branchGroups: [BranchPopupGroup] {
        let grouped = Dictionary(grouping: filteredReferences) { reference -> String in
            switch reference.kind {
            case .remote: return "Remote"
            case .tag: return "Tags"
            case .local:
                return "Local"
            }
        }

        return grouped.map { title, references in
            let kind = references.first?.kind ?? .local
            return BranchPopupGroup(
                title: title,
                kind: kind,
                references: references.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.title.isEmpty != rhs.title.isEmpty { return lhs.title.isEmpty }
            if lhs.kind != rhs.kind { return popupKindOrder(lhs.kind) < popupKindOrder(rhs.kind) }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actionMatches(_ title: String) -> Bool {
        normalizedQuery.isEmpty || title.localizedCaseInsensitiveContains(normalizedQuery)
    }

    private func referenceIcon(_ reference: GitReference) -> String {
        if reference.isCurrent { return "star.fill" }
        switch reference.kind {
        case .local: return "point.3.connected.trianglepath.dotted"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }

    private func branchDisplayName(_ reference: GitReference, insideGroup: Bool) -> String {
        guard insideGroup, reference.kind == .local else { return reference.shortName }
        return reference.shortName.split(separator: "/").last.map(String.init) ?? reference.shortName
    }

    private func popupKindOrder(_ kind: GitReferenceKind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .tag: 2
        }
    }
}

private struct BranchPopupGroup: Identifiable {
    let title: String
    let kind: GitReferenceKind
    let references: [GitReference]

    var id: String { "\(kind.rawValue):\(title)" }
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
