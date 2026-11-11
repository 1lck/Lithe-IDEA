package workbench

import (
	"os"
	"os/exec"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// openWorktreeInNewWindow shows the checkout at path in a window of its own: a new client is
// started with the folder on its command line, which opens it when the window starts (see
// Options.OpenPath). The current window and its project are left as they are.
func (a *App) openWorktreeInNewWindow(path string) {
	a.performed("git.worktree.openNewWindow", surfaceButton)
	exe, err := os.Executable()
	if err == nil {
		cmd := exec.Command(exe, path)
		err = cmd.Start()
		if err == nil {
			// The new client runs on its own; the current one does not wait for it.
			go func() { _ = cmd.Wait() }()
		}
	}
	if err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.worktree.openNewWindowFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}
