import Foundation

/// Decides which Git context-menu actions make sense for a file entry in the
/// project tree. Mirrors the Windows capability helper: a file without a Git
/// change entry gets no menu at all, and an already staged entry hides `Add`
/// because staging it again is a no-op. `canToggleStaging` is honored because
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
        self.showsAdd = change.canToggleStaging && !change.isStaged
        self.showsStageAndOpenCommit = true
    }
}
