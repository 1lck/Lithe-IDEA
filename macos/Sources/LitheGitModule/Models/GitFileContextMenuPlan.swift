import Foundation

/// Decides which Git context-menu actions make sense for a file entry in the
/// project tree. Mirrors the Windows capability helper: a file without a Git
/// change entry gets no menu at all; partially staged files keep `Add` to
/// include remaining worktree edits. `canToggleStaging` is honored because
/// it is the established macOS gating flag for staging actions.
package struct GitFileContextMenuPlan: Equatable, Sendable {
    package let showsAdd: Bool
    package let showsStageAndOpenCommit: Bool

    package init(change: GitChange?) {
        guard let change else {
            self.showsAdd = false
            self.showsStageAndOpenCommit = false
            return
        }
        self.showsAdd = change.canToggleStaging && (!change.isStaged || change.hasWorkingTreeChange)
        self.showsStageAndOpenCommit = true
    }
}
