package workbench

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// This file keeps the state and the actions of the Push dialog and of the stash, worktree and
// repository tools. Core resolves the push destination and validates every write; the dialogs
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
	// busy is set while the push runs.
	busy bool
}

// openPush opens the Push dialog on the checked-out branch and reads Core's preview.
func (a *App) openPush(p *project) {
	if _, ok := a.reviewKernel(); !ok || !p.git.isRepository() {
		return
	}
	s := &p.review.push
	*s = pushState{open: true, gen: s.gen + 1}
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
	gen, tags, target, root := s.gen, pushTagChoices[s.tags], s.target, p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitPushPreviewOf(ctx, root, core.GitReference{}, tags, target)
		return func(a *App) {
			s := &p.review.push
			if !s.open || s.gen != gen {
				return
			}
			s.loading = false
			if err != nil {
				s.err, s.hasPrev = a.reviewText("git.pushDialog.previewFailed")+" "+reviewReason(err), false
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
	a.runSync(p, "git_push", a.reviewText("git.pushing"), func(reason string) string {
		return a.reviewFormat("desktop.gitReview.operationFailed", map[string]string{"reason": reason})
	}, func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
		pusher, ok := kernel.(gitReviewKernel)
		if !ok {
			return nil, errors.New("push is not available")
		}
		if err := pusher.GitPush(ctx, root, preview, tags, target, force); err != nil {
			return nil, err
		}
		return func(a *App) { a.notify(a.reviewText("git.changesPushed")) }, nil
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

// --- Stashes, worktrees and repositories ---

// toolsTab names the tab of the tools dialog.
type toolsTab int

const (
	toolsStashes toolsTab = iota
	toolsWorktrees
	toolsRepositories
)

// toolsState is the open stash, worktree and repository tools dialog.
type toolsState struct {
	open    bool
	tab     toolsTab
	loading bool
	gen     int
	busy    bool
	// err is why the last read failed; writeErr why the last write did. A read clears only err,
	// so a failed write stays visible after the lists reload.
	err      string
	writeErr string

	stashes      []core.GitStash
	worktrees    []core.GitWorktree
	repositories []core.WorkspaceRepository

	// stashMessage and untracked shape the next stash; the worktree fields shape the next new
	// worktree, created on a new branch started at the checked-out one.
	stashMessage ui.Field
	untracked    bool
	branchName   ui.Field
	destination  ui.Field
	// removing is the worktree path waiting for the user to confirm its removal.
	removing string
	// dropping is the stash identity waiting for the user to confirm dropping it.
	dropping string

	stashList, treeList, repoList ui.ListState
}

// openTools opens the tools dialog on a tab and reads its lists.
func (a *App) openTools(p *project, tab toolsTab) {
	if _, ok := a.reviewKernel(); !ok {
		return
	}
	t := &p.review.tools
	t.open, t.tab, t.err, t.writeErr, t.removing, t.dropping = true, tab, "", "", "", ""
	a.performed("git.tools.open", surfaceMenu)
	a.loadTools(p)
}

// closeTools closes the dialog.
func (a *App) closeTools(p *project) {
	t := &p.review.tools
	t.open = false
	t.gen++
}

// loadTools reads the three lists of the dialog in one background step.
func (a *App) loadTools(p *project) {
	kernel, ok := a.reviewKernel()
	t := &p.review.tools
	if !ok {
		return
	}
	t.loading, t.gen = true, t.gen+1
	gen, root, folder := t.gen, p.git.repositoryRoot(p.root), p.root
	repository := p.git.isRepository()
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		var (
			stashes   []core.GitStash
			trees     []core.GitWorktree
			err, rErr error
		)
		if repository {
			if stashes, err = kernel.GitStashes(ctx, root); err == nil {
				trees, err = kernel.GitWorktrees(ctx, root)
			}
		}
		repos, rErr := kernel.DiscoverWorkspaceRepositories(ctx, folder)
		return func(a *App) {
			t := &p.review.tools
			if !t.open || t.gen != gen {
				return
			}
			t.loading = false
			t.stashes, t.worktrees, t.repositories = stashes, trees, repos
			switch {
			case err != nil:
				t.err = reviewReason(err)
				a.gitOperationFailed("git_tools_read", err)
			case rErr != nil:
				t.err = reviewReason(rErr)
				a.gitOperationFailed("git_repositories", rErr)
			default:
				t.err = ""
			}
		}
	})
}

// toolsWrite runs one write of the tools dialog, then reads the lists and the status again
// whatever the outcome. The failure is shown in the dialog.
func (a *App) toolsWrite(p *project, operation string, write func(ctx context.Context, kernel gitReviewKernel, root string) error) {
	kernel, ok := a.reviewKernel()
	t := &p.review.tools
	if !ok || t.busy {
		return
	}
	t.busy, t.writeErr, t.removing, t.dropping = true, "", "", ""
	root := p.git.repositoryRoot(p.root)
	a.performed("git."+operation, surfaceButton)
	a.background(p, syncTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root)
		return func(a *App) {
			t := &p.review.tools
			t.busy = false
			a.loadGit(p)
			if err != nil {
				t.writeErr = reviewReason(err)
				a.gitOperationFailed(operation, err)
			}
			if t.open {
				a.loadTools(p)
			}
		}
	})
}

// stashChanges stashes the local changes with the typed message.
func (a *App) stashChanges(p *project) {
	t := &p.review.tools
	message, untracked := strings.TrimSpace(t.stashMessage.Text()), t.untracked
	a.toolsWrite(p, "git_stash_push", func(ctx context.Context, k gitReviewKernel, root string) error {
		return k.GitStashPush(ctx, root, message, untracked)
	})
	t.stashMessage.SetText("")
}

// stashAction applies, pops or drops one stash by its immutable identity.
func (a *App) stashAction(p *project, stash core.GitStash, action string) {
	a.toolsWrite(p, "git_stash_"+action, func(ctx context.Context, k gitReviewKernel, root string) error {
		switch action {
		case "apply":
			return k.GitStashApply(ctx, root, stash)
		case "pop":
			return k.GitStashPop(ctx, root, stash)
		}
		return k.GitStashDrop(ctx, root, stash)
	})
}

// createWorktree adds a worktree on a new branch started at the checked-out branch in the typed directory.
func (a *App) createWorktree(p *project) {
	t := &p.review.tools
	name, destination := strings.TrimSpace(t.branchName.Text()), strings.TrimSpace(t.destination.Text())
	branch := p.git.branch()
	if name == "" || destination == "" || branch == "" || branch == "detached" {
		return
	}
	// The new branch starts at the checked-out one, named by its complete reference identity.
	from := core.GitReference{FullName: "refs/heads/" + branch, ShortName: branch, Kind: "local"}
	a.toolsWrite(p, "git_worktree_create", func(ctx context.Context, k gitReviewKernel, root string) error {
		return k.GitCreateWorktree(ctx, root, destination, core.GitWorktreeNewBranch, name, from)
	})
	t.branchName.SetText("")
	t.destination.SetText("")
}

// worktreeAction removes, locks or unlocks one registered worktree, or prunes the missing ones.
func (a *App) worktreeAction(p *project, tree core.GitWorktree, action string) {
	a.toolsWrite(p, "git_worktree_"+action, func(ctx context.Context, k gitReviewKernel, root string) error {
		switch action {
		case "lock":
			return k.GitLockWorktree(ctx, root, tree.Path)
		case "unlock":
			return k.GitUnlockWorktree(ctx, root, tree.Path)
		case "prune":
			return k.GitPruneWorktrees(ctx, root)
		}
		return k.GitRemoveWorktree(ctx, root, tree.Path, false)
	})
}

// hasPrunable reports that a registered worktree's checkout is gone.
func hasPrunable(trees []core.GitWorktree) bool {
	return slices.ContainsFunc(trees, func(t core.GitWorktree) bool { return t.IsPrunable })
}
