package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// gitTimeout bounds one Git status read of the open project.
const gitTimeout = 30 * time.Second

// gitState is what the window knows about the open project's Git repository. The shell
// only shows the branch in the title bar and the number of changes in the status bar, so
// it keeps nothing but the kernel's status answer.
type gitState struct {
	// loaded is set once the kernel answered, whether it succeeded or failed.
	loaded bool
	status core.GitStatus
	err    error
}

// loadGit asks the kernel for the Git status of p and keeps the answer in p.git. The
// answer is dropped when p is no longer the open project by the time it arrives.
func (a *App) loadGit(p *project) {
	kernel, root := a.kernel, p.root
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		status, err := kernel.GitStatus(ctx, root)
		return func(a *App) {
			a.setGit(p, gitState{loaded: true, status: status, err: err})
			if err != nil {
				a.notify(a.text.Git.Failed(err.Error()))
				return
			}
			// The markers and the inline blame describe the file against the index and
			// HEAD, so a new status can change both.
			a.refreshGitGutters(p)
			a.refreshInlineBlames(p)
		}
	})
}

// isRepository reports that the kernel answered and found a repository around the project.
func (g gitState) isRepository() bool {
	return g.loaded && g.err == nil && g.status.RepositoryRoot != ""
}

// branch is the checked-out branch, empty outside a repository or before the answer.
func (g gitState) branch() string {
	if !g.isRepository() {
		return ""
	}
	return g.status.Branch
}

// changeCount is the number of changed paths; ok is false while there is no repository
// status to count.
func (g gitState) changeCount() (count int, ok bool) {
	if !g.isRepository() {
		return 0, false
	}
	return len(g.status.Changes), true
}
