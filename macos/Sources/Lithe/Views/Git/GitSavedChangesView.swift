import SwiftUI
import LitheGitModule

/// SavedPatchesUi: records above, changed files and restore actions below.
struct GitSavedChangesView: View {
    @ObservedObject var feature: GitFeatureModel
    let isActive: Bool
    let openDiff: (GitSavedChangesSnapshot, String, GitCommitFile) -> Void
    let dropStash: (GitStash) -> Void
    let dropShelf: (GitShelfEntry) -> Void
    @Environment(\.locale) private var locale
    @State private var stash: GitStash?
    @State private var shelf: GitShelfEntry?
    @State private var snapshot: GitSavedChangesSnapshot?
    @State private var failure: String?
    @State private var loading = false
    @State private var version = ""
    @State private var selectedFile: GitCommitFile?
    @State private var collapsed: Set<String> = []
    @State private var retry = 0
    @State private var submitting = false
    @State private var creating = false
    @State private var creatingShelf = false
    @State private var message = "WIP"
    @State private var includeUntracked = true

    private var busy: Bool { submitting || feature.isPerformingStashOperation || feature.isPerformingShelfOperation }
    private var loadID: String {
        "\(feature.gitRepositoryRoot?.path ?? ""):\(stash.map { String(describing: $0) } ?? shelf?.id.uuidString ?? ""):\(retry)"
    }
    private var files: [GitCommitFile] { snapshot?.files.filter { $0.version == version }.map(\.file) ?? [] }
    private var tree: GitCommitFileTreeNode {
        .build(from: files, rootName: feature.gitRepositoryRoot?.lastPathComponent ?? "")
    }

    var body: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(axis: .vertical, placement: .leading,
                defaultSize: geometry.size.height * 0.5, minimum: 80,
                maximum: max(80, geometry.size.height - 160), flexibleMinimum: 160, highlightsOnHover: false) {
                records
            } flexible: {
                VStack(spacing: 0) {
                    toolbar
                    LitheToolWindowHeaderDivider()
                    details
                    LitheToolWindowHeaderDivider()
                    actions
                }
            }
        }
        .task(id: loadID) { await load() }
        .onAppear(perform: selectRequestedStash)
        .onChange(of: feature.requestedStashReference) { _ in selectRequestedStash() }
        .onChange(of: feature.gitRepositoryRoot) { _ in stash = nil; shelf = nil }
        .onChange(of: feature.gitStashes) { values in
            if let stash, !values.contains(stash) { self.stash = nil }
        }
        .onChange(of: feature.gitShelves) { values in
            if let shelf, !values.contains(where: { $0.id == shelf.id }) { self.shelf = nil }
        }
        .background(LitheCenteredPopup(isPresented: $creating, allowsDismiss: !busy,
            dialogTitle: String(localized: creatingShelf ? "Shelve Changes" : "Stash Changes", locale: locale)) {
            GitSaveChangesDialog(message: $message, includeUntracked: $includeUntracked,
                shelf: creatingShelf, busy: busy, cancel: { creating = false }, save: save)
        }.frame(width: 0, height: 0).allowsHitTesting(false))
    }

    private var records: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !feature.gitShelves.isEmpty {
                    section("Lithe Shelves")
                    ForEach(feature.gitShelves) { entry in
                        record(title: entry.message, detail: "\(entry.paths.count) files", date: entry.createdAt.formatted(), branch: false,
                               selected: shelf?.id == entry.id, menu: [
                                .action("Restore") { Task { await feature.applyShelf(entry) } },
                                .action("Drop", role: .destructive) { dropShelf(entry) }
                               ]) { shelf = entry; stash = nil }
                        .help(entry.createdAt.formatted())
                    }
                    section("Git Stashes")
                }
                ForEach(feature.gitStashes) { entry in
                    record(title: entry.message.isEmpty ? entry.reference : entry.message,
                           detail: entry.branch ?? "", date: entry.date, branch: true, selected: stash == entry, menu: [
                            .action("Apply") { Task { await feature.applyStash(entry) } },
                            .action("Pop") { Task { await feature.applyStash(entry, pop: true) } },
                            .separator,
                            .action("Drop", role: .destructive) { dropStash(entry) }
                           ]) { stash = entry; shelf = nil }
                    .help("\(entry.reference) · \(entry.date)")
                }
                if feature.gitShelves.isEmpty && feature.gitStashes.isEmpty {
                    Text("No saved changes").foregroundStyle(LitheTheme.secondaryText).padding(12)
                }
            }.padding(.horizontal, 8).padding(.vertical, 4)
        }.litheScrollViewChrome()
    }

    private func section(_ title: String) -> some View {
        Text(LocalizedStringKey(title)).font(LitheTheme.uiFont(size: 12))
            .foregroundStyle(LitheTheme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func record(title: String, detail: String, date: String, branch: Bool, selected: Bool, menu: [LitheContextMenuItem], action: @escaping () -> Void) -> some View {
        GitSavedChangesRow(accessibilityTitle: "\(title), \(date), \(detail)", onPress: action, menu: menu) { expanded, hovered in
            HStack(spacing: 4) {
                Text(title).foregroundStyle(LitheTheme.primaryText).lineLimit(1)
                if expanded { Text(date).foregroundStyle(LitheTheme.secondaryText).fixedSize() }
                if branch && !detail.isEmpty {
                    LitheIDEAIcon(resourcePath: "dvcs/branchLabel", size: 16)
                        .foregroundStyle(detail == feature.currentBranch ? LitheTheme.Commit.savedHeadIcon : LitheTheme.Commit.savedBranchIcon)
                }
                Text(detail).foregroundStyle(selected && isActive ? LitheTheme.primaryText : LitheTheme.secondaryText).lineLimit(1)
                if !expanded { Spacer(minLength: 0) }
            }
            .font(LitheTheme.uiFont(size: 13)).padding(.horizontal, 4)
            .frame(height: LitheTheme.Tree.rowHeight).fixedSize(horizontal: expanded, vertical: true)
            .background(selected ? (isActive ? LitheTheme.Tree.focusedSelection : LitheTheme.Tree.inactiveSelection) : (hovered ? LitheTheme.Tree.hover : .clear))
            .background(LitheTheme.sidebar)
        }
        .frame(height: LitheTheme.Tree.rowHeight)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            icon("expui/general/show", "Show Diff", enabled: selectedFile != nil) { showDiff() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            icon("savedChanges/stash", "Stash Changes", enabled: !busy && !feature.activeRepositoryChanges.isEmpty) {
                creatingShelf = false; creating = true
            }
            icon("savedChanges/shelve", "Shelve Changes", enabled: !busy && !feature.activeRepositoryChanges.isEmpty) {
                creatingShelf = true; creating = true
            }
            if let snapshot, snapshot.versions.count > 1 {
                LitheMenu {
                    snapshot.versions.map { value in
                        LitheContextMenuItem.action(value) { version = value; selectedFile = nil; collapsed = [] }
                    }
                } label: { Text(LocalizedStringKey(version)).font(LitheTheme.uiFont(size: 12)) }
                .buttonStyle(.litheNoPress)
            }
            Spacer(minLength: 0)
            icon("expui/general/expandAll", "Expand All", enabled: !files.isEmpty) { collapsed = [] }
            icon("expui/general/collapseAll", "Collapse All", enabled: !files.isEmpty) { collapsed = [tree.id] }
        }.padding(.horizontal, 8).frame(height: LitheTheme.Commit.toolbarHeight)
    }

    private func icon(_ path: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LitheIDEAIcon(resourcePath: path, size: 16, preservesOriginalColors: true)
        }.litheToolbarIconButton(isEnabled: enabled)
            .help(LocalizedStringKey(title)).accessibilityLabel(LocalizedStringKey(title))
    }

    @ViewBuilder private var details: some View {
        if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if let failure {
            VStack(spacing: 8) {
                Text(failure).foregroundStyle(LitheTheme.warning)
                Button("Retry") { retry += 1 }.buttonStyle(LitheCommitDialogButtonStyle())
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            Text(snapshot == nil ? "Select saved changes" : "No changed files")
                .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GitCommitFileTreeScrollView(items: GitCommitFileTreeItem.visibleItems(tree, collapsed: collapsed),
                selectedFileID: selectedFile?.id, rootSubtitle: nil, collapsedFolderIDs: collapsed,
                onToggleFolder: { if !collapsed.insert($0).inserted { collapsed.remove($0) } },
                onSelectFile: { selectedFile = $0; showDiff() })
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(shelf == nil ? "Apply" : "Restore") {
                if let stash { Task { await feature.applyStash(stash) } }
                if let shelf { Task { await feature.applyShelf(shelf) } }
            }.buttonStyle(LitheCommitDialogButtonStyle(primary: true)).disabled(busy || (stash == nil && shelf == nil))
            if shelf == nil {
                Button("Pop") { if let stash { Task { await feature.applyStash(stash, pop: true) } } }
                    .buttonStyle(LitheCommitDialogButtonStyle()).disabled(busy || stash == nil)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func showDiff() {
        guard let snapshot, let selectedFile else { return }
        openDiff(snapshot, version, selectedFile)
    }

    private func selectRequestedStash() {
        guard let reference = feature.requestedStashReference,
              let entry = feature.gitStashes.first(where: { $0.reference == reference }) else { return }
        stash = entry; shelf = nil
    }

    private func load() async {
        snapshot = nil; selectedFile = nil; failure = nil; collapsed = []
        guard stash != nil || shelf != nil else { loading = false; return }
        loading = true
        let result = await feature.loadSavedChanges(stash: stash, shelf: shelf)
        guard !Task.isCancelled else { return }
        loading = false
        switch result {
        case .success(let value): snapshot = value; version = value.versions.first ?? ""
        case .failure(let error): failure = error.localizedDescription
        }
    }

    private func save() {
        guard !busy else { return }
        let isShelf = creatingShelf
        submitting = true
        Task {
            if isShelf { await feature.shelveWorkingTree(message: message) }
            else { await feature.stashWorkingTree(message: message, includeUntracked: includeUntracked) }
            creating = false
            submitting = false
        }
    }
}

private struct GitSaveChangesDialog: View {
    @Binding var message: String
    @Binding var includeUntracked: Bool
    let shelf: Bool
    let busy: Bool
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Name:")
                TextField("Save message", text: $message)
                    .focused($focused).modifier(LitheCommitDialogInputStyle(focused: focused))
                    .onSubmit(save)
            }
            if !shelf { Toggle("Untracked", isOn: $includeUntracked).toggleStyle(.checkbox) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(LitheCommitDialogButtonStyle()).keyboardShortcut(.cancelAction)
                Button(shelf ? "Shelf" : "Stash", action: save)
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.font(LitheTheme.uiFont(size: 13)).padding(12).frame(width: 360)
            .background(LitheCommitDialogStyle.background).disabled(busy)
            .task { focused = true }
    }
}

/// Reuses the branch popup's bounded, clickable hover expansion lifecycle with tree-row styling.
struct GitSavedChangesRow<Label: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    @Environment(\.isLithePaneResizing) private var resizing
    let accessibilityTitle: String
    let onPress: () -> Void
    var menu: [LitheContextMenuItem] = []
    @ViewBuilder let label: (Bool, Bool) -> Label

    func makeNSView(context: Context) -> BranchPopupRowControl { BranchPopupRowControl() }
    func updateNSView(_ view: BranchPopupRowControl, context: Context) {
        view.isEnabled = environment.isEnabled && !resizing
        view.isPresented = false
        view.onPress = onPress
        view.onSecondaryPress = { [weak view] point in
            LitheContextMenuPresenter.shared.show(items: menu, at: point,
                appearance: view?.effectiveAppearance, locale: environment.locale, parentWindow: view?.window)
        }
        view.setAccessibilityLabel(accessibilityTitle)
        view.render = { expanded, highlighted in
            AnyView(label(expanded, highlighted).environment(\.self, environment))
        }
        view.refresh()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchPopupRowControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? LitheDropdownMetrics.branchMinimumWidth, height: LitheTheme.Tree.rowHeight)
    }
}
