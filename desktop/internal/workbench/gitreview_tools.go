package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file keeps the state and the actions of the Push dialog and of the repositories
// dialog. Core resolves the push destination and validates every write; the dialogs
// show its answers and send the reviewed ones back.

// pushTagChoices are the tag policies of the Push dialog, in the order of its select.
var pushTagChoices = []core.GitPushTags{core.GitPushTagsNone, core.GitPushTagsReachable, core.GitPushTagsAll}

// pushState is the open Push dialog.
type pushState struct {
	open    bool
	loading bool
	gen     int
	err     string
	preview core.GitPushPreview
	hasPrev bool
	// tags indexes pushTagChoices; force asks for a force push bound to the reviewed commit.
	tags  int
	force bool
	// target answers a divergent destination; empty until the user picks one.
	target core.PushTargetChoice
	// root is the repository the dialog pushes from, and branch the local branch it pushes,
	// empty for the checked-out one.
	root   string
	branch core.GitReference
	// busy is set while the push runs.
	busy bool
}

// openPush opens the Push dialog on the branch checked out in the repository the log walks.
func (a *App) openPush(p *project) { a.openPushOf(p, p.logRepositoryRoot(), core.GitReference{}) }

// openPushOf opens the Push dialog on the local branch of the repository at root, the
// checked-out one when branch is empty, and reads Core's preview.
func (a *App) openPushOf(p *project, root string, branch core.GitReference) {
	if _, ok := a.reviewKernel(); !ok || !p.git.isRepository() {
		return
	}
	s := &p.review.push
	*s = pushState{open: true, gen: s.gen + 1, root: root, branch: branch}
	a.performed("git.push.open", surfaceMenu)
	a.loadPush(p)
}

// closePush closes the dialog; it stays open while a push runs, which has its own Cancel.
func (a *App) closePush(p *project) {
	s := &p.review.push
	if s.busy {
		return
	}
	s.open = false
	s.gen++
}

// loadPush reads the push preview with the choices made so far.
func (a *App) loadPush(p *project) {
	kernel, ok := a.reviewKernel()
	s := &p.review.push
	if !ok {
		return
	}
	s.loading, s.err, s.gen = true, "", s.gen+1
	gen, tags, target, root, branch := s.gen, pushTagChoices[s.tags], s.target, s.root, s.branch
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitPushPreviewOf(ctx, root, branch, tags, target)
		return func(a *App) {
			s := &p.review.push
			if !s.open || s.gen != gen {
				return
			}
			s.loading = false
			if err != nil {
				s.err, s.hasPrev = i18n.Shared(a.language(), "git.pushDialog.previewFailed")+" "+reviewReason(err), false
				a.gitOperationFailed("git_push_preview", err)
				return
			}
			s.preview, s.hasPrev = preview, true
		}
	})
}

// canPush reports that the reviewed preview may be sent: it has commits or a new branch to
// publish, and a divergent destination has been answered.
func (s *pushState) canPush() bool {
	if !s.hasPrev || s.loading || s.busy {
		return false
	}
	if s.preview.TargetKind == "divergent" && s.target == "" {
		return false
	}
	return len(s.preview.Commits) > 0 || s.preview.CreatesRemoteBranch
}

// submitPush sends the reviewed commits and shows Git's progress in the dialog.
func (a *App) submitPush(p *project) {
	s := &p.review.push
	if !s.canPush() || p.log.sync.busy {
		return
	}
	preview, tags, target, force := s.preview, pushTagChoices[s.tags], s.target, s.force
	a.performed("git.push", surfaceButton)
	s.busy = true
	a.runSyncAt(p, s.root, "git_push", i18n.Shared(a.language(), "git.pushing"), func(reason string) string {
		return i18n.SharedFormat(a.language(), "desktop.gitReview.operationFailed", map[string]string{"reason": reason})
	}, func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
		pusher, ok := kernel.(gitReviewKernel)
		if !ok {
			return nil, errors.New("push is not available")
		}
		if err := pusher.GitPush(ctx, root, preview, tags, target, force); err != nil {
			return nil, err
		}
		return func(a *App) { a.notifySuccess(i18n.Shared(a.language(), "git.changesPushed")) }, nil
	})
	// The dialog follows the outcome: it closes on success, and after a rejected or stale push
	// it reviews the repository as it is now.
	p.log.sync.done = func(a *App, err error) {
		s := &p.review.push
		s.busy = false
		if err == nil {
			s.open = false
			return
		}
		a.loadPush(p)
	}
}

// --- Repositories ---

// toolsState is the open dialog of the repositories Core discovered under the project folder.
// The stashes have the Commit tool window's Stash tab (stash.go) and the worktrees the Git tool
// window's Worktrees tab (gitworktree.go).
type toolsState struct {
	open    bool
	loading bool
	gen     int
	// err is why the last read failed.
	err string

	repositories []core.WorkspaceRepository
	repoList     ui.ListState
}

// openTools opens the repositories dialog and reads the list.
func (a *App) openTools(p *project) {
	if _, ok := a.reviewKernel(); !ok {
		return
	}
	t := &p.review.tools
	t.open, t.err = true, ""
	a.performed("git.tools.open", surfaceMenu)
	a.loadTools(p)
}

// closeTools closes the dialog.
func (a *App) closeTools(p *project) {
	t := &p.review.tools
	t.open = false
	t.gen++
}

// loadTools reads the repositories of the dialog in the background.
func (a *App) loadTools(p *project) {
	kernel, ok := a.reviewKernel()
	t := &p.review.tools
	if !ok {
		return
	}
	t.loading, t.gen = true, t.gen+1
	gen, folder := t.gen, p.root
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		repos, err := kernel.DiscoverWorkspaceRepositories(ctx, folder)
		return func(a *App) {
			t := &p.review.tools
			if !t.open || t.gen != gen {
				return
			}
			t.loading, t.repositories = false, repos
			if err != nil {
				t.err = reviewReason(err)
				a.gitOperationFailed("git_repositories", err)
				return
			}
			t.err = ""
		}
	})
}
