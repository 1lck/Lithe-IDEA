import AppKit
import LitheModuleAPI
import SwiftUI
import LitheGitModule

/// Inclusion here is only a rollback draft: toggling never stages a file.
struct GitRollbackDialog: View {
    @State var selection: GitRollbackSelection
    let onClose: () -> Void
    let onRollback: (GitRollbackSelection) -> Void
    @State private var highlightedIDs: Set<String> = []
    @State private var collapsedFolders: Set<String> = []

    private struct Row: Identifiable {
        let id: String
        let root: URL
        let name: String
        let depth: Int
        let changes: [GitChange]
        let change: GitChange?
    }

    private var rows: [Row] {
        var roots: [URL] = []
        var seen: Set<URL> = []
        let groups = Dictionary(grouping: selection.changes) { $0.repositoryRoot.standardizedFileURL }
        for change in selection.changes {
            let root = change.repositoryRoot.standardizedFileURL
            if seen.insert(root).inserted { roots.append(root) }
        }
        return roots.flatMap { root in
            let changes = groups[root] ?? []
            let tree = GitCommitFileTreeNode.build(from: changes.map {
                GitCommitFile(status: $0.displayStatus, path: $0.path)
            }, rootName: root.lastPathComponent)
            let byPath = Dictionary(grouping: changes, by: \.path)
            func append(_ node: GitCommitFileTreeNode, depth: Int) -> [Row] {
                let id = "folder:" + root.path + ":" + node.id
                let descendants = changes.filter { node.path.isEmpty || $0.path.hasPrefix(node.path + "/") }
                var result = [Row(id: id, root: root, name: node.name, depth: depth, changes: descendants, change: nil)]
                guard !collapsedFolders.contains(id) else { return result }
                for directory in node.directories { result += append(directory, depth: depth + 1) }
                for file in node.files {
                    for change in byPath[file.path] ?? [] {
                        result.append(Row(id: change.id, root: root, name: change.url.lastPathComponent,
                            depth: depth + 1, changes: [change], change: change))
                    }
                }
                return result
            }
            return append(tree, depth: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LitheTreeList(rows, id: \.id, selection: $highlightedIDs, hierarchy: { row in
                .init(depth: row.depth, isBranch: row.change == nil,
                      isExpanded: !collapsedFolders.contains(row.id))
            }, onExpansion: { row, expanded in
                if expanded { collapsedFolders.remove(row.id) } else { collapsedFolders.insert(row.id) }
            }) { row in
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheTreeCheckbox(state: checkboxState(row.changes), accessibilityTitle: "Include in rollback") {
                        selection.toggle(row.changes)
                    }
                    .accessibilityIdentifier("git-rollback-include-" + row.id)
                    if let change = row.change {
                        LitheIcon(kind: LitheIcons.kind(for: change.url, isDirectory: change.isUntrackedDirectory),
                                  size: LitheTheme.Tree.iconSize)
                        Text(verbatim: row.name).foregroundStyle(change.fileNameColor)
                            .lineLimit(1).help(change.url.path)
                    } else {
                        LitheIcon(kind: .folder, size: LitheTheme.Tree.iconSize)
                        Text(verbatim: row.name).help(row.root.path)
                        Text("\(row.changes.reduce(0) { $0 + $1.fileCount }) files").foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }.font(LitheTheme.uiFont(size: 13))
            }
            .frame(minHeight: 220, idealHeight: 320, maxHeight: .infinity)
            .background(LitheTheme.inputBackground)

            Text("\(selection.includedChanges.reduce(0) { $0 + $1.fileCount }) files selected")
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
            Toggle("Delete local copies of added files", isOn: $selection.deleteAddedFiles)
                .toggleStyle(.checkbox).disabled(!selection.hasIncludedAdditions)
            Text("Staged and unstaged changes in the checked files will be rolled back. This cannot be undone by Lithe.")
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.warning)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("git-rollback-close")
                Button("Rollback") { onRollback(selection) }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true)).keyboardShortcut(.defaultAction)
                    .disabled(selection.includedChanges.isEmpty)
                    .accessibilityIdentifier("git-rollback-confirm")
            }
        }
        .padding(20).frame(width: 540, height: 520)
        .background(LitheCommitDialogStyle.background)
    }

    private func checkboxState(_ changes: [GitChange]) -> NSControl.StateValue {
        let included = changes.filter { selection.includedIDs.contains($0.id) }.count
        return included == changes.count ? .on : included == 0 ? .off : .mixed
    }
}

struct GitRollbackPresentation: ViewModifier {
    @ObservedObject var feature: GitFeatureModel
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.background(LitheCenteredPopup(isPresented: Binding(
            get: { feature.pendingRollbackSelection != nil },
            set: { if !$0 { feature.cancelRollbackChanges() } }),
            dialogTitle: L10n.string("Rollback Changes", locale: locale)) {
                if let selection = feature.pendingRollbackSelection {
                    GitRollbackDialog(selection: selection, onClose: { feature.cancelRollbackChanges() }, onRollback: { captured in
                        feature.cancelRollbackChanges()
                        Task { await feature.confirmRollbackChanges(captured) }
                    }).id(selection.id)
                }
            }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
