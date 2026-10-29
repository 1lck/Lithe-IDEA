import AppKit
import SwiftUI
import LitheGitModule

/// Worktree-local actions reuse Commit's staging/discard services and native
/// viewport; opening a diff never switches the active repository implicitly.
struct GitWorktreeChangesView: View {
    @ObservedObject var feature: GitFeatureModel
    let worktree: GitWorktree
    let snapshot: GitWorktreeRowsSnapshot
    let actions: GitWorktreeActions
    var commitSession: WorktreeCommitSession? = nil
    var hasBackgroundImage = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var selection = GitChangeSelection()
    @State private var pendingDiscard: [GitChange] = []
    @State private var collapsedLists: Set<String> = []
    @State private var sectionsCache = GitChangeSectionsCache()

    private var changes: [GitChange] {
        guard feature.gitWorktreeInspection?.worktreeID == worktree.id else { return [] }
        return feature.gitWorktreeInspection?.changes ?? []
    }

    private var enabled: Bool {
        !feature.isMutatingWorktreeChanges && !feature.isRefreshingWorktreeChanges
            && !feature.isPerformingWorktreeOperation && !feature.isCommitting && !feature.isStagingChanges
            && commitSession?.feature.changelistEditingDisabled != true && commitSession?.feature.isWorktreeCommitBlocked != true
    }

    /// Checkboxes stay painted as usable while a toggle is being applied, so rapid clicking
    /// does not flash them grey. Only a refresh or operation the user started greys them.
    private var checkboxesLookEnabled: Bool {
        !feature.isPerformingWorktreeOperation && !feature.isCommitting
            && commitSession?.feature.isCommitting != true && commitSession?.feature.changelistStorageFailed != true
            && !(feature.isRefreshingWorktreeChanges && !feature.isMutatingWorktreeChanges)
    }

    /// Requested staged states Git has not confirmed yet, by change ID. While the row
    /// projection trails a fresh status read, the fresh states stand in for the old rows.
    private var stagedOverrides: [GitChange.ID: Bool] {
        var overrides = feature.pendingStagedStates
        if snapshot.identity != .changes(inspectionVersion: feature.gitWorktreeInspectionVersion) {
            for change in changes where overrides[change.id] == nil { overrides[change.id] = change.isStaged }
        }
        return overrides
    }

    var body: some View {
        let files = fileList
        Group {
            if let commitSession {
                let composer = CommitAreaView(feature: commitSession.feature, draft: commitSession.draft,
                    commitWorkflow: commitSession.workflow, hasBackgroundImage: hasBackgroundImage,
                    showSettings: { _ in actions.showCommitSettings() })
                GeometryReader { geometry in
                    let layout = GitWorktreeChangesLayout(size: geometry.size)
                    LitheSplitPaneView(axis: layout.axis, placement: .trailing,
                        defaultSize: layout.commitSize, minimum: layout.commitMinimum, maximum: layout.commitMaximum,
                        flexibleMinimum: layout.listMinimum, clipsSizedPane: true,
                        dividerColor: LitheTheme.toolWindowBorder(for: colorScheme), sized: { composer }, flexible: { files })
                }
            } else { files }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                toolbarButton("Refresh changes", icon: "expui/general/refresh.svg", enabled: enabled) {
                    Task { await feature.refreshWorktreeChanges(worktree) }
                }
                // Same set as the Commit toolbar. Only discarding needs a selection, because it cannot
                // be undone; the rest work on every file when nothing is selected.
                toolbarButton("Stage all files", icon: "expui/general/download.svg",
                    enabled: enabled && activeChanges.contains { GitFileContextMenuPlan(change: $0).showsAdd }) {
                    setStaging(activeChanges, true)
                }
                toolbarButton("Discard selected change", icon: "expui/vcs/revert.svg",
                    enabled: enabled && targets.contains(where: \.hasWorkingTreeChange)) { pendingDiscard = targets }
                toolbarButton("Show Diff", icon: "expui/general/show.svg",
                    enabled: diffTarget != nil && actions.showChange != nil) {
                    if let diffTarget { actions.showChange?(diffTarget) }
                }
                Spacer(minLength: 0)
                if feature.isMutatingWorktreeChanges || feature.isRefreshingWorktreeChanges {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: LitheTheme.Commit.toolbarHeight)

            if let commitSession {
                GitChangelistBar(feature: commitSession.feature, showsParentReferences: false)
            }
            if let error = feature.worktreeChangesError {
                Text(error).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error)
                    .textSelection(.enabled).padding(.vertical, 6)
            }
            if changes.isEmpty {
                Text("No local changes")
                    .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let overrides = stagedOverrides
                if commitSession == nil {
                    let allStaged = changes.allSatisfy { overrides[$0.id] ?? $0.isStaged }
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        LitheTreeCheckbox(state: stagingState(overrides), accessibilityTitle: "Include in commit") {
                            guard enabled else { return }
                            setStaging(changes, !allStaged)
                        }
                        .disabled(!checkboxesLookEnabled || !changes.contains(where: \.canToggleStaging))
                        .help(allStaged ? "Unstage all files" : "Stage all files")
                        Text("\(changes.reduce(0) { $0 + $1.fileCount }) files")
                            .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, LitheTheme.Tree.horizontalInset * 2)
                }

                LitheTreeList(native: GitWorktreeRowsScrollView(snapshot: displayed(overrides), contextID: worktree.id,
                    interaction: GitWorktreeChangeInteraction(selectedIDs: selection.ids, isEnabled: enabled,
                        paintsAsEnabled: checkboxesLookEnabled,
                        onSelection: { selection.replace(with: $0) },
                        onToggle: { change in
                            setStaging(selection.actionTargets(in: changes, clicked: change), !(overrides[change.id] ?? change.isStaged))
                        }, onOpen: { actions.showChange?($0) }, menuItems: menu,
                        onToggleList: { list in
                            setStaging(list, !list.filter(\.canToggleStaging).allSatisfy { overrides[$0.id] ?? $0.isStaged })
                        }, onExpandList: { id in
                            if !collapsedLists.insert(id).inserted { collapsedLists.remove(id) }
                        })))
            }
        }
        .onChange(of: changes) { selection.retain($0.map(\.id)) }
        .confirmationDialog("Discard changes to selected files?",
            isPresented: Binding(get: { !pendingDiscard.isEmpty }, set: { if !$0 { pendingDiscard = [] } }),
            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                let captured = pendingDiscard
                pendingDiscard = []
                Task { await feature.discardWorktreeChanges(captured, in: worktree) }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = [] }
        } message: {
            Text(worktree.path + "\n" + pendingDiscard.map(\.path).joined(separator: "\n"))
            Text("This action cannot be undone by Lithe. Untracked files will be deleted.")
        }
    }

    private var targets: [GitChange] { selection.actionTargets(in: changes) }

    private var activeChanges: [GitChange] { commitSession?.feature.activeChangelistChanges ?? changes }

    /// The selected file, or the first one when nothing is selected.
    private var diffTarget: GitChange? {
        targets.first { !$0.isUntrackedDirectory } ?? changes.first { !$0.isUntrackedDirectory }
    }

    private func displayed(_ overrides: [GitChange.ID: Bool]) -> GitWorktreeRowsSnapshot {
        var displayed = snapshot
        if let scoped = commitSession?.feature {
            let sections = sectionsCache.sections(changes: changes, conflictFilterPaths: [], changelists: scoped.changelists)
            let rows = sections.changelists.flatMap { section -> [GitWorktreeRowsSnapshot.Row] in
                let expanded = !collapsedLists.contains(section.id)
                let name = section.id == GitLocalChangelists.defaultID
                    ? gitLocalizedFormat("Default ChangeList", locale: locale) : section.list.name
                return [.changelist(id: section.id, name: name, changes: section.changes, expanded: expanded)]
                    + (expanded ? section.changes.map(GitWorktreeRowsSnapshot.Row.change) : [])
            }
            displayed = GitWorktreeRowsSnapshot(identity: snapshot.identity, rows: rows)
        }
        displayed.stagedOverrides = overrides
        return displayed
    }

    private func stagingState(_ overrides: [GitChange.ID: Bool]) -> NSControl.StateValue {
        let staged = { (change: GitChange) in overrides[change.id] ?? change.isStaged }
        return changes.allSatisfy(staged) ? .on : changes.contains(where: staged) ? .mixed : .off
    }

    private func setStaging(_ changes: [GitChange], _ staged: Bool) {
        Task { await feature.setWorktreeStaging(changes, staged: staged, in: worktree) }
    }

    private func toolbarButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LitheIDEAIcon(resourcePath: icon, size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
        }
        .litheToolbarIconButton(isEnabled: enabled)
        .help(LocalizedStringKey(title))
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityIdentifier("worktree-changes-" + title)
    }

    func menu(for change: GitChange) -> [LitheContextMenuItem] {
        let targets = selection.actionTargets(in: changes, clicked: change)
        return [
            .action("Open", isEnabled: !change.isUntrackedDirectory && change.kind != .deleted && actions.openFile != nil) {
                actions.openFile?(change.url, change.path)
            },
            .action("Show Diff", isEnabled: !change.isUntrackedDirectory && actions.showChange != nil) { actions.showChange?(change) },
            .submenu("Move to ChangeList", items: commitSession?.feature.changelists.lists.map { list in
                .action(list.displayName, isEnabled: enabled) { commitSession?.feature.moveChanges(targets, toChangelist: list.id) }
            } ?? []),
            .separator,
            .action("Stage Files", isEnabled: enabled && targets.contains { GitFileContextMenuPlan(change: $0).showsAdd }) { setStaging(targets, true) },
            .action("Unstage Files", isEnabled: enabled && targets.contains(where: \.isStaged)) { setStaging(targets, false) },
            .action("Discard Changes", role: .destructive, isEnabled: enabled && targets.contains(where: \.hasWorkingTreeChange)) { pendingDiscard = targets },
            .separator,
            .action("Show in Finder") { actions.reveal(change.kind == .deleted ? change.url.deletingLastPathComponent() : change.url) },
            .action("Copy Path") { actions.copyPath(change.url) }
        ]
    }
}

/// Keep both panes usable in narrow detail columns; resizing remains local to
/// the shared split rather than publishing every drag into Git state.
struct GitWorktreeChangesLayout {
    let axis: LitheSplitAxis
    let commitSize: CGFloat
    let commitMinimum: CGFloat
    let commitMaximum: CGFloat
    let listMinimum: CGFloat

    init(size: CGSize) {
        let horizontal = size.width >= 620
        axis = horizontal ? .horizontal : .vertical
        let available = max(0, (horizontal ? size.width : size.height) - SplitHandleView.thickness)
        let verticalListMinimum = LitheTheme.Commit.toolbarHeight + 4 * LitheTheme.Tree.rowHeight + 2 * LitheTheme.Tree.verticalInset
        listMinimum = min(horizontal ? 280 : verticalListMinimum, available * 0.5)
        commitMinimum = min(horizontal ? 320 : LitheTheme.Commit.areaMinimumHeight, available - listMinimum)
        commitMaximum = max(commitMinimum, available - listMinimum)
        commitSize = min(commitMaximum, max(commitMinimum, available * (horizontal ? 0.52 : 0.55)))
    }
}
