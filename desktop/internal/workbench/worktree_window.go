package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// openWorktreeInNewWindow shows the checkout at path in a window of its own: a new client is
// started with the folder on its command line, which opens it when the window starts (see
// Options.OpenPath). The current window and its project are left as they are.
func (a *App) openWorktreeInNewWindow(path string) {
	// A remote workspace's checkout is a host folder; a new client would open its placeholder as
	// a local folder.
	if a.refuseRemote(a.project, "worktree_open_new_window") {
		return
	}
	a.performed("git.worktree.openNewWindow", surfaceButton)
	if err := launchClient(path); err != nil {
		a.operationFailed("worktree_open_new_window", documentLogError(err))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.worktree.openNewWindowFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}
