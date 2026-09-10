import LitheGitModule

@MainActor
enum GitHistoryRewriteMenu {
    static func items(feature: GitFeatureModel, commit: GitCommit) -> [LitheContextMenuItem] {
        guard let root = feature.gitRepositoryRoot else { return [] }
        let editor = feature.historyEditing
        let count = editor.selection.hashes.count
        let historyItems: [LitheContextMenuItem] = [.separator] + GitHistoryRewriteOperation.allCases.map { operation in
            .action(
                operation.menuTitle,
                role: operation == .deleteCommit ? .destructive : .standard,
                isEnabled: !feature.isPerformingBranchOperation && !editor.isBusy
                    && (operation == .squashCommits ? count > 1 : count == 1),
                action: { editor.begin(operation, at: root, clickedHash: commit.hash) }
            )
        }
        let selected = feature.gitCommits.filter { editor.selection.hashes.contains($0.hash) }
        return historyItems + [
            .action("Interactively Rebase from Here…", isEnabled: count == 1 && !feature.isPerformingBranchOperation && !feature.isResolvingGitOperation && !feature.interactiveRebase.isBusy) {
                feature.interactiveRebase.begin(at: root, baseRevision: commit.hash)
            },
            .separator,
            .action("Create Patch Between Commits…", isEnabled: count == 2 && selected.count == 2 && !feature.patchExchange.isBusy) {
                guard let base = selected.last, let target = selected.first else { return }
                feature.patchExchange.beginCommitExport(at: root, base: base.hash, target: target.hash)
            }
        ]
    }
}
