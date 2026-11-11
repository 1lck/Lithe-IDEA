package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file runs the interactive rebase "Rebase from Here" (matrix id git-rebase-stash): the
// commit menu of the log opens a dialog that previews the commits after the chosen one, each
// with its action (pick, fixup or drop), and starts the reviewed plan through Core. A rebase
// that stops at a conflict or is still running is kept as the project's session and shown with
// Continue, Skip and Abort on the Commit tool window (git_rebase_view.go). Reword, edit and
// squash need a message and are not offered here.

// rebaseActions are the actions the dialog offers, in the order its choice lists them.
var rebaseActions = []string{"pick", "fixup", "drop"}

// rebaseState is the rebase dialog of a project and the session of its last rebase.
type rebaseState struct {
	open bool
	// gen counts the previews started; an answer of an older preview is dropped.
	gen     int
	busy    bool
	base    string
	subject string
	preview core.RebasePreview
	// actions holds the chosen action of each commit of the preview, by hash.
	actions map[string]string
	err     string
	list    ui.ListState
	// session is the last rebase session the repository holds, nil when there is none.
	session *core.RebaseSession
}

// rebaseKernel is the part of the kernel a rebase uses. *core.Client implements it.
type rebaseKernel interface {
	GitRebasePreview(ctx context.Context, root, base string) (core.RebasePreview, error)
	GitRebaseStart(ctx context.Context, root string, preview core.RebasePreview, steps []core.RebaseStep) (*core.RebaseSession, error)
	GitRebaseSession(ctx context.Context, root string) (*core.RebaseSession, error)
	GitRebaseControl(ctx context.Context, root string, session core.RebaseSession, action, amendMessage, expectedHead string) (*core.RebaseSession, error)
}

// rebaseDone reports that a session has nothing left to continue.
func rebaseDone(status string) bool {
	return status == "completed" || status == "aborted"
}

// beginRebaseFromHere opens the rebase dialog on the commits after base and reads their preview.
func (a *App) beginRebaseFromHere(p *project, base, subject string) {
	if _, ok := a.kernel.(rebaseKernel); !ok {
		return
	}
	r := &p.rebase
	r.gen++
	gen := r.gen
	*r = rebaseState{open: true, gen: gen, busy: true, base: base, subject: subject, session: r.session}
	kernel, root := a.kernel.(rebaseKernel), p.git.repositoryRoot(p.root)
	a.performed("git.rebase.fromHere", surfaceMenu)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitRebasePreview(ctx, root, base)
		return func(a *App) {
			r := &p.rebase
			if !r.open || r.gen != gen {
				return
			}
			r.busy = false
			if err != nil {
				r.err = reviewReason(err)
				a.gitOperationFailed("git_rebase_preview", err)
				return
			}
			r.preview = preview
			r.actions = map[string]string{}
			for _, commit := range preview.Commits {
				r.actions[commit.Hash] = "pick"
			}
		}
	})
}

// closeRebase closes the dialog and drops the preview it waits for.
func (a *App) closeRebase(p *project) {
	r := &p.rebase
	r.open = false
	r.gen++
}

// startRebase runs the reviewed plan of the open dialog: every commit of the preview once, in
// the order it replays, with the action the user chose.
func (a *App) startRebase(p *project) {
	kernel, ok := a.kernel.(rebaseKernel)
	r := &p.rebase
	if !ok || r.busy || len(r.preview.Commits) == 0 {
		return
	}
	steps := make([]core.RebaseStep, 0, len(r.preview.Commits))
	for _, commit := range r.preview.Commits {
		steps = append(steps, core.RebaseStep{Hash: commit.Hash, Action: r.actions[commit.Hash]})
	}
	preview := r.preview
	r.busy = true
	a.performed("git.rebase.start", surfaceButton)
	root := p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		session, err := kernel.GitRebaseStart(ctx, root, preview, steps)
		return func(a *App) {
			r := &p.rebase
			r.busy = false
			if err != nil {
				r.err = reviewReason(err)
				a.gitOperationFailed("git_rebase_start", err)
				return
			}
			r.open = false
			r.session = session
			a.afterRebaseWrite(p)
		}
	})
}

// controlRebase continues, skips or aborts the session the repository holds.
func (a *App) controlRebase(p *project, action string) {
	kernel, ok := a.kernel.(rebaseKernel)
	r := &p.rebase
	if !ok || r.busy || r.session == nil {
		return
	}
	session := *r.session
	r.busy = true
	a.performed("git.rebase."+action, surfaceButton)
	root := p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		next, err := kernel.GitRebaseControl(ctx, root, session, action, "", "")
		return func(a *App) {
			r := &p.rebase
			r.busy = false
			if err != nil {
				a.notify(i18n.SharedFormat(a.language(), "desktop.rebase.controlFailed", map[string]string{"reason": reviewReason(err)}))
				a.gitOperationFailed("git_rebase_control", err)
				a.loadRebaseSession(p)
				return
			}
			r.session = next
			a.afterRebaseWrite(p)
		}
	})
}

// loadRebaseSession reads the repository's latest rebase session in the background, so a
// rebase that stopped at a conflict is still shown after a restart.
func (a *App) loadRebaseSession(p *project) {
	kernel, ok := a.kernel.(rebaseKernel)
	if !ok || !p.git.isRepository() {
		return
	}
	root := p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		session, err := kernel.GitRebaseSession(ctx, root)
		return func(a *App) {
			if err == nil {
				p.rebase.session = session
			}
		}
	})
}

// afterRebaseWrite reads the status, the log and the session again after a rebase moved HEAD.
func (a *App) afterRebaseWrite(p *project) {
	a.loadGit(p)
	if p.log.started {
		a.loadLog(p)
	}
	if p.rebase.session != nil {
		a.notify(i18n.SharedFormat(a.language(), "desktop.rebase.status", map[string]string{"status": p.rebase.session.Status}))
	}
}
