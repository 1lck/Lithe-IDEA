package workbench

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The menu of the log tab fetches the remotes and updates the checked out branch. Both talk
// to a remote, so they can take long: they run in the background with a status line and a
// Cancel button, and their failures are worded for the user (a refused sign-in says what
// to set up). Core runs Git and decides how histories combine; this file sequences the
// calls and keeps the dialogs' state.

// syncTimeout bounds one fetch or update, with its network wait.
const syncTimeout = 10 * time.Minute

// syncDialog says which dialog of the log tab's sync operations is open.
type syncDialog int

const (
	syncDialogNone syncDialog = iota
	// syncDialogFetch asks for the options of one fetch.
	syncDialogFetch
	// syncDialogDiverged asks how to combine a diverged branch with its upstream.
	syncDialogDiverged
)

// The choices of the fetch dialog's two selects, in the order of syncSubmoduleChoices and
// syncTagChoices.
var (
	syncSubmoduleChoices = []core.GitFetchSubmodules{core.GitFetchSubmodulesInherit, core.GitFetchSubmodulesNo, core.GitFetchSubmodulesOnDemand, core.GitFetchSubmodulesYes}
	syncTagChoices       = []core.GitFetchTags{core.GitFetchTagsInherit, core.GitFetchTagsAll, core.GitFetchTagsNone, core.GitFetchTagsPrune}
)

// syncState is what the log tab of a project knows about its fetch and update operations.
type syncState struct {
	dialog syncDialog
	// busy is set while an operation runs; label words it, and cancel stops it.
	busy   bool
	label  string
	cancel context.CancelFunc

	// The fetch dialog: one remote instead of all, whether stale tracking branches stay,
	// and the picked submodule and tag policies.
	onlyRemote    bool
	remote        ui.Field
	keepStale     bool
	submodules    int
	tags          int
	submoduleSel  ui.SelectState
	tagSel        ui.SelectState
	remoteProblem string

	// preflight and branch are what the diverged dialog is about.
	preflight core.GitPullPreflight
	branch    string
}

// fetchOptions are the options the fetch dialog describes.
func (s *syncState) fetchOptions() core.GitFetchOptions {
	options := core.DefaultGitFetchOptions()
	if s.onlyRemote {
		remote := strings.TrimSpace(s.remote.Text())
		options.Remote = &remote
	}
	options.Prune = !s.keepStale
	options.Submodules = syncSubmoduleChoices[s.submodules]
	options.Tags = syncTagChoices[s.tags]
	return options
}

// runSync runs work against the repository of p in the background, with the status line
// and Cancel button. work returns what to do on the UI thread once it succeeded. The status
// and the log are read again afterwards whatever the outcome, since a failed fetch may have
// moved some references.
func (a *App) runSync(p *project, operation, label string, failed func(reason string) string,
	work func(ctx context.Context, kernel Kernel, root string) (func(*App), error)) {
	s := &p.log.sync
	if s.busy {
		return
	}
	op, cancel := context.WithCancel(p.ctx)
	s.busy, s.label, s.cancel = true, label, cancel
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, syncTimeout, func(ctx context.Context) func(*App) {
		ctx, stop := context.WithCancel(ctx)
		defer stop()
		defer context.AfterFunc(op, stop)()
		done, err := work(ctx, kernel, root)
		readCtx, readCancel := context.WithTimeout(p.ctx, gitTimeout)
		defer readCancel()
		status, statusErr := kernel.GitStatus(readCtx, p.root)
		return func(a *App) {
			s := &p.log.sync
			s.busy, s.cancel = false, nil
			cancel()
			if statusErr == nil {
				p.git = gitState{loaded: true, status: status}
			}
			if p.log.started {
				a.loadLog(p)
			}
			switch {
			case err == nil:
				if done != nil {
					done(a)
				}
			case errors.Is(err, context.Canceled):
				a.notify(a.text.Sync.Cancelled)
			case core.IsAuthenticationFailure(err):
				a.notify(a.text.Sync.AuthFailed(syncReason(err)))
				a.gitOperationFailed(operation, err)
			default:
				a.notify(failed(syncReason(err)))
				a.gitOperationFailed(operation, err)
			}
		}
	})
}

// syncReason is the line of err to show: Git's own first line when Core gave one.
func syncReason(err error) string {
	var e *core.Error
	if errors.As(err, &e) && e.Message != "" {
		return e.Message
	}
	return err.Error()
}

// cancelSync stops the operation in flight.
func (a *App) cancelSync(p *project) {
	if s := &p.log.sync; s.busy && s.cancel != nil {
		s.cancel()
	}
}

// fetchAll fetches every remote of p with Core's default options.
func (a *App) fetchAll(p *project) {
	a.performed("git.fetch", surfaceMenu)
	a.runSync(p, "git_fetch", a.text.Sync.Fetching(), a.text.Sync.FetchFailed,
		func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
			return func(a *App) { a.notify(a.text.Sync.Fetched) }, kernel.GitFetch(ctx, root, nil)
		})
}

// openFetchOptions opens the dialog that fetches with chosen options.
func (a *App) openFetchOptions(p *project) {
	s := &p.log.sync
	if s.busy {
		return
	}
	s.dialog = syncDialogFetch
	s.onlyRemote, s.keepStale, s.submodules, s.tags = false, false, 0, 0
	s.remote.SetText("")
}

// submitFetchOptions fetches with the options of the open dialog.
func (a *App) submitFetchOptions(p *project) {
	s := &p.log.sync
	options := s.fetchOptions()
	if options.Remote != nil && *options.Remote == "" {
		return
	}
	s.dialog = syncDialogNone
	a.performed("git.fetch.options", surfaceButton)
	a.runSync(p, "git_fetch", a.text.Sync.Fetching(), a.text.Sync.FetchFailed,
		func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
			return func(a *App) { a.notify(a.text.Sync.Fetched) }, kernel.GitFetch(ctx, root, &options)
		})
}

// updateCurrentBranch fetches, then brings the checked out branch up to its upstream. A
// branch that has diverged asks how to combine, unless Git's configuration already says.
func (a *App) updateCurrentBranch(p *project) {
	branch := p.log.current
	if branch == "" {
		return
	}
	a.performed("git.updateBranch", surfaceMenu)
	t := a.text.Sync
	a.runSync(p, "git_update_branch", t.Updating(branch), t.UpdateFailed,
		func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
			if err := kernel.GitFetch(ctx, root, nil); err != nil {
				return nil, err
			}
			pre, err := kernel.GitPullPreflight(ctx, root)
			if err != nil {
				return nil, err
			}
			switch {
			case pre.Upstream == "":
				return func(a *App) { a.notify(a.text.Sync.NoUpstream(branch)) }, nil
			case pre.IsUpToDate():
				return func(a *App) { a.notify(a.text.Sync.UpToDate(branch)) }, nil
			case pre.Diverged && pre.ConfiguredStrategy == "":
				return func(a *App) {
					s := &p.log.sync
					s.dialog, s.preflight, s.branch = syncDialogDiverged, pre, branch
				}, nil
			}
			strategy := pre.ConfiguredStrategy
			if strategy == "" {
				strategy = core.GitPullFastForward
			}
			return func(a *App) { a.notify(a.text.Sync.Updated(branch)) }, kernel.GitPull(ctx, root, strategy)
		})
}

// resolveDiverged combines the diverged branch with its upstream the way the user chose.
func (a *App) resolveDiverged(p *project, strategy core.GitPullStrategy) {
	s := &p.log.sync
	branch := s.branch
	s.dialog = syncDialogNone
	t := a.text.Sync
	a.performed("git.pull", surfaceButton)
	a.runSync(p, "git_pull", t.Updating(branch), t.UpdateFailed,
		func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
			done := func(a *App) {
				if strategy == core.GitPullRebase {
					a.notify(a.text.Sync.Rebased(branch))
				} else {
					a.notify(a.text.Sync.Merged(branch))
				}
			}
			return done, kernel.GitPull(ctx, root, strategy)
		})
}

// showChanges opens the Commit tool window, which lists the working tree changes.
func (a *App) showChanges() {
	a.performed("git.showChanges", surfaceMenu)
	if !a.chrome.isOpen(catalogIndex[itemCommit]) {
		a.reduceChrome(core.SetChromeOpen(itemCommit, true))
	}
}
