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
    @State private var selection = GitChangeSelection()
    @State private var pendingDiscard: [GitChange] = []

    private var changes: [GitChange] {
        guard feature.gitWorktreeInspection?.worktreeID == worktree.id else { return [] }
        return feature.gitWorktreeInspection?.changes ?? []
    }

    private var enabled: Bool {
        !feature.isMutatingWorktreeChanges && !feature.isRefreshingWorktreeChanges
            && !feature.isPerformingWorktreeOperation && !feature.isCommitting && !feature.isStagingChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                toolbarButton("Refresh changes", icon: "expui/general/refresh.svg", enabled: enabled) {
                    Task { await feature.refreshWorktreeChanges(worktree) }
                }
                toolbarButton("Stage Files", icon: "expui/general/add.svg",
                    enabled: enabled && targets.contains { GitFileContextMenuPlan(change: $0).showsAdd }) {
                    setStaging(targets, true)
                }
                toolbarButton("Unstage Files", icon: "expui/vcs/revert.svg",
                    enabled: enabled && targets.contains(where: \.isStaged)) { setStaging(targets, false) }
                toolbarButton("Discard selected change", icon: "expui/vcs/revert.svg",
                    enabled: enabled && targets.contains(where: \.hasWorkingTreeChange)) { pendingDiscard = targets }
                toolbarButton("Show Diff", icon: "expui/general/show.svg",
                    enabled: targets.contains { !$0.isUntrackedDirectory } && actions.showChange != nil) {
                    if let first = targets.first(where: { !$0.isUntrackedDirectory }) { actions.showChange?(first) }
                }
                Spacer(minLength: 0)
                if feature.isMutatingWorktreeChanges || feature.isRefreshingWorktreeChanges {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: LitheTheme.Commit.toolbarHeight)

            if let error = feature.worktreeChangesError {
                Text(error).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error)
                    .textSelection(.enabled).padding(.vertical, 6)
            }
            if changes.isEmpty {
                Text("No local changes")
                    .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheTreeCheckbox(state: stagingState, accessibilityTitle: "Include in commit") {
                        setStaging(changes, !changes.allSatisfy(\.isStaged))
                    }
                    .disabled(!enabled || !changes.contains(where: \.canToggleStaging))
                    .help(changes.allSatisfy(\.isStaged) ? "Unstage all files" : "Stage all files")
                    Text("\(changes.reduce(0) { $0 + $1.fileCount }) files")
                        .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                    Spacer(minLength: 0)
                }.padding(.horizontal, LitheTheme.Tree.horizontalInset * 2)

                LitheTreeList(native: GitWorktreeRowsScrollView(snapshot: snapshot, contextID: worktree.id,
                    interaction: GitWorktreeChangeInteraction(selectedIDs: selection.ids, isEnabled: enabled,
                        onSelection: { selection.replace(with: $0) },
                        onToggle: { change in
                            setStaging(selection.actionTargets(in: changes, clicked: change), !change.isStaged)
                        }, onOpen: { actions.showChange?($0) }, menuItems: menu)))
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

    private var stagingState: NSControl.StateValue {
        changes.allSatisfy(\.isStaged) ? .on : changes.contains(where: \.isStaged) ? .mixed : .off
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
