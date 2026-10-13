import SwiftUI
import LitheGitModule

struct DiffHunkActionsView: View {
    let feature: GitFeatureModel
    let hunk: DiffHunk
    let change: GitChange
    let isMutationEnabled: Bool

    var body: some View {
        HStack(spacing: 2) {
            if change.hasWorkingTreeChange {
                Button {
                    Task { await feature.stageDiffHunk(hunk, in: change) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .litheIconButton()
                .disabled(!isMutationEnabled)
                .help("Stage this change block").accessibilityLabel("Stage this change block")

                Button {
                    feature.requestDiscardHunk(hunk, in: change)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .litheIconButton()
                .disabled(!isMutationEnabled)
                .help("Discard this change block").accessibilityLabel("Discard this change block")
            } else if change.isStaged {
                Button {
                    Task { await feature.unstageDiffHunk(hunk, in: change) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .litheIconButton()
                .disabled(!isMutationEnabled)
                .help("Unstage this change block").accessibilityLabel("Unstage this change block")
            }
        }
        .padding(.trailing, 6)
        .frame(height: 27)
        .background(LitheTheme.raised.opacity(0.92))
    }
}
