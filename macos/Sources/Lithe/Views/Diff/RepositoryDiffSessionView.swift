import SwiftUI
import LitheGitModule

/// Observes the pane's session rather than whichever Diff has global focus.
struct RepositoryDiffSessionView: View {
    @EnvironmentObject private var model: AppModel
    /// Used only to run actions. Observing it re-rendered every mounted diff on any Git publish.
    let feature: GitFeatureModel
    @ObservedObject var session: GitRepositoryDiffSession
    let fontFamily: String

    var body: some View {
        Group {
            if let comparison = session.branchComparison {
                BranchComparisonView(feature: feature, session: session, comparison: comparison,
                    onRefresh: {
                        let root = session.comparisonRoot
                        if let target = comparison.targetReference {
                            await feature.showComparison(from: comparison.reference, to: target, session: session, repositoryRoot: root)
                        } else {
                            await feature.showComparisonWithWorkingTree(for: comparison.reference, session: session, repositoryRoot: root)
                        }
                    }, fontFamily: fontFamily)
            } else if let change = session.selectedChange {
                RepositoryDiffView(feature: feature, session: session, change: change,
                    onClose: { model.closeRepositoryDiffTab(session.id) },
                    onOpenFile: { model.openFile(change.url) }, fontFamily: fontFamily)
            } else if let context = session.selectedGitCommitDiffContext {
                RepositoryDiffView(feature: feature, session: session, context: context,
                    onClose: { model.closeRepositoryDiffTab(session.id) },
                    onOpenFile: { model.openFile(context.url) },
                    onOpenCommitDiff: { file in
                        if let snapshot = session.savedDiffSnapshot, let version = session.savedDiffVersion {
                            model.showSavedChangesDiff(snapshot, version: version, file: file)
                        } else {
                            model.showGitCommitDiff(for: file, context: context, files: session.commitFiles)
                        }
                    }, fontFamily: fontFamily)
            } else if session.isLoadingBranchComparison {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No textual diff available")
                    .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
