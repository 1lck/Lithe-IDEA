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
	// tree is the same answer indexed for the project tree, which colors the rows of the
	// changed paths. It is rebuilt whenever the status is replaced.
	tree treeStatus
}

// loadGit asks the kernel for the Git status of p and keeps the answer in p.git. The
// answer is dropped when the project closes or a newer status read starts. The status
// is read again on every repository change, too often for the console, so its queries belong
// to no category.
func (a *App) loadGit(p *project) {
	a.readGit(p, core.AutomaticRefresh)
}

// reloadGit is loadGit after a Git operation the user ran, or the Changes refresh the user
// asked for: the console records its queries when it records reloads (GitQueryReload).
func (a *App) reloadGit(p *project) {
	a.readGit(p, func(ctx context.Context) context.Context {
		return core.WithQueryCategory(core.AutomaticRefresh(ctx), core.GitQueryReload)
	})
}

// readGit reads the status of p under the context policy gives its request.
func (a *App) readGit(p *project, policy func(context.Context) context.Context) {
	generation := p.gitStatusGeneration.Add(1)
	kernel, root := a.kernel, p.root
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		status, err := kernel.GitStatus(policy(ctx), root)
		return func(a *App) {
			wasRepo := p.git.isRepository()
			if !a.setGit(p, gitState{loaded: true, status: status, err: err}, generation) {
				return
			}
			if err != nil {
				a.operationFailed("git_status", err)
				a.notifyError(a.text.Git.Failed(err.Error()))
				return
			}
			a.gitStatusPublished(p)
			// Load or clear the log once GitStatus determines whether p.root is a repository.
			if p.git.isRepository() != wasRepo && p.log.started && !p.walksSeveral() && p.logRepo() == nil {
				a.loadLog(p)
			}
		}
	})
}

// gitStatusPublished reads again what a new status of p can change. Whoever publishes the status
// runs it: a read the status of a branch write or a sync superseded is dropped with these reads.
func (a *App) gitStatusPublished(p *project) {
	// The markers and the inline blame describe the file against the index and HEAD, so a new
	// status can change both.
	a.refreshGitGutters(p)
	a.refreshInlineBlames(p)
	a.loadNestedRepos(p)
	a.loadRebaseSession(p)
	a.loadGitOperation(p)
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
