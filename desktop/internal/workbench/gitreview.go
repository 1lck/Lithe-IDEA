package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file keeps the state and the actions of the Git review features that the Commit tool
// window and the Git menu open: the Push dialog, the stash and repository tools, the blame
// annotations, the listing of a summarized untracked directory and the rollback confirmation.
// The Diff of a file is a tab of the editor area, kept in difftab.go. Core decides everything
// about Git (which destination a push goes to, what a rollback runs); this file sequences the
// calls and keeps what the dialogs show. gitreview_diff_view.go and gitreview_tools_view.go
// declare the dialogs.

const (
	// reviewTimeout bounds one read or write of a review dialog.
	reviewTimeout = gitTimeout
	// blameFileLimit is the most bytes of a file the blame dialog reads for its text.
	blameFileLimit = 4 << 20
	// reviewDialogWidth and reviewDialogHeight size the wide dialogs.
	reviewDialogWidth  = 860
	reviewDialogHeight = 560
	reviewRowHeight    = 20
)

// gitReviewKernel is what the review dialogs ask of the kernel. The real client answers all of
// it; a window whose kernel does not simply offers none of these features.
type gitReviewKernel interface {
	GitDiff(ctx context.Context, request core.GitDiffRequest) ([]core.GitDiffFile, error)
	PlanDiffBlocks(ctx context.Context, target core.DiffBlockTarget) (core.DiffBlockPlan, error)
	ApplyDiffBlock(ctx context.Context, plan core.DiffBlockPlan, target core.DiffBlockTarget, blockID string, action core.DiffBlockAction) error
	GitBlame(ctx context.Context, root, path string) ([]core.GitBlameLine, error)
	GitUntrackedDirectory(ctx context.Context, root, directory string) ([]core.GitChange, error)
	GitStage(ctx context.Context, root string, paths []string) error
	GitRollbackPrepare(ctx context.Context, root string, changes []core.GitChange, deleteAdded bool) ([]core.GitRollbackStep, error)
	GitRunRollbackStep(ctx context.Context, root string, step core.GitRollbackStep) error
	GitStashes(ctx context.Context, root string) ([]core.GitStash, error)
	GitStashPush(ctx context.Context, root, message string, includeUntracked bool) error
	GitStashApply(ctx context.Context, root string, stash core.GitStash) error
	GitStashPop(ctx context.Context, root string, stash core.GitStash) error
	GitStashDrop(ctx context.Context, root string, stash core.GitStash) error
	GitStashDiff(ctx context.Context, root string, stash core.GitStash) ([]core.GitDiffFile, error)
	GitComparison(ctx context.Context, root string, base core.GitReference, target *core.GitReference) ([]core.GitComparisonFile, error)
	GitPushPreviewOf(ctx context.Context, root string, branch core.GitReference, tags core.GitPushTags, target core.PushTargetChoice) (core.GitPushPreview, error)
	GitPush(ctx context.Context, root string, preview core.GitPushPreview, tags core.GitPushTags, target core.PushTargetChoice, force bool) error
	DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error)
	changedFileGrouper
}

// reviewKernel is the window's kernel as the review dialogs use it.
func (a *App) reviewKernel() (gitReviewKernel, bool) {
	k, ok := a.kernel.(gitReviewKernel)
	return k, ok
}

// gitReview is the state of a project's review dialogs. It is reset when the project closes.
type gitReview struct {
	push      pushState
	tools     toolsState
	blame     blameState
	untracked untrackedState
	rollback  rollbackState
}

// reviewReason is the line of err to show: Git's own first line when Core gave one.
func reviewReason(err error) string {
	var e *core.Error
	if errors.As(err, &e) && e.Message != "" {
		return e.Message
	}
	return err.Error()
}

// reviewFailed words a failed review operation for the user and logs it.
func (a *App) reviewFailed(operation string, err error) {
	a.notifyError(i18n.SharedFormat(a.language(), "desktop.gitReview.operationFailed", map[string]string{"reason": reviewReason(err)}))
	a.gitOperationFailed(operation, err)
}

// --- Blame ---

// blameState is the open annotation dialog: the blame of every line, with the file's text.
type blameState struct {
	open    bool
	loading bool
	gen     int
	path    string
	err     string
	lines   []core.GitBlameLine
	text    []string
	list    ui.ListState
}

// openBlame opens the annotations of a tracked file of the project, with the text read from
// the saved file.
func (a *App) openBlame(p *project, relative string) {
	kernel, ok := a.reviewKernel()
	if !ok {
		return
	}
	b := &p.review.blame
	*b = blameState{open: true, loading: true, gen: b.gen + 1, path: relative, list: b.list}
	gen, root := b.gen, p.git.repositoryRoot(p.root)
	disk := filepath.Join(root, filepath.FromSlash(relative))
	a.performed("git.blame.open", surfaceMenu)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		lines, err := kernel.GitBlame(ctx, root, relative)
		var text []string
		if err == nil {
			text, err = readBlameText(disk)
		}
		return func(a *App) {
			b := &p.review.blame
			if !b.open || b.gen != gen {
				return
			}
			b.loading = false
			if err != nil {
				b.err = i18n.SharedFormat(a.language(), "desktop.gitReview.blameFailed", map[string]string{"reason": reviewReason(err)})
				a.gitOperationFailed("git_blame", err)
				return
			}
			b.lines, b.text = lines, text
		}
	})
}

// readBlameText reads the lines of the saved file the blame refers to, bounded in size.
func readBlameText(file string) ([]string, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data := make([]byte, blameFileLimit)
	n, err := f.Read(data)
	if err != nil && n == 0 {
		return nil, nil
	}
	return strings.Split(strings.TrimSuffix(string(data[:n]), "\n"), "\n"), nil
}

// blameDate is the date a blame line was authored on, in the viewer's time zone.
func blameDate(line core.GitBlameLine) string {
	return time.Unix(line.AuthorTime, 0).Format("2006-01-02")
}

// --- Untracked directories ---

// untrackedState is the open listing of a summarized untracked directory. trail holds the
// directories entered, the last being the one listed.
type untrackedState struct {
	open    bool
	loading bool
	gen     int
	trail   []string
	err     string
	changes []core.GitChange
	list    ui.ListState
}

// openUntracked lists the one level of the summarized directory directory ("dir/").
func (a *App) openUntracked(p *project, directory string) {
	u := &p.review.untracked
	*u = untrackedState{open: true, gen: u.gen + 1, trail: []string{directory}, list: u.list}
	a.loadUntracked(p)
}

// loadUntracked reads the directory the dialog stands in.
func (a *App) loadUntracked(p *project) {
	kernel, ok := a.reviewKernel()
	u := &p.review.untracked
	if !ok || len(u.trail) == 0 {
		return
	}
	u.loading, u.gen = true, u.gen+1
	gen, directory, root := u.gen, u.trail[len(u.trail)-1], p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		changes, err := kernel.GitUntrackedDirectory(ctx, root, directory)
		return func(a *App) {
			u := &p.review.untracked
			if !u.open || u.gen != gen {
				return
			}
			u.loading = false
			if err != nil {
				u.err = reviewReason(err)
				a.gitOperationFailed("git_untracked_directory", err)
				return
			}
			u.err, u.changes = "", changes
		}
	})
}

// enterUntracked descends into a subdirectory summary, and leaveUntracked goes back up.
func (a *App) enterUntracked(p *project, directory string) {
	u := &p.review.untracked
	u.trail = append(u.trail, directory)
	a.loadUntracked(p)
}

func (a *App) leaveUntracked(p *project) {
	u := &p.review.untracked
	if len(u.trail) > 1 {
		u.trail = u.trail[:len(u.trail)-1]
		a.loadUntracked(p)
	}
}

// stageUntracked stages one path of the listing and reads the project's status again.
func (a *App) stageUntracked(p *project, change core.GitChange) {
	kernel, ok := a.reviewKernel()
	if !ok {
		return
	}
	root := p.git.repositoryRoot(p.root)
	a.performed("git.stage", surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		err := kernel.GitStage(ctx, root, change.StagingPaths())
		return func(a *App) {
			a.loadGit(p)
			if err != nil {
				a.reviewFailed("git_stage", err)
				return
			}
			if u := &p.review.untracked; u.open {
				a.loadUntracked(p)
			}
		}
	})
}

// --- Rollback ---

// rollbackState is the open rollback confirmation of one or more changes.
type rollbackState struct {
	open bool
	busy bool
	// root is the checkout the changes are in: the project's repository or another of its
	// worktrees.
	root        string
	changes     []core.GitChange
	deleteAdded bool
	// console says the rollback shows the Console tab of the Git tool window: it was asked
	// for outside the Git tool window, in the Commit tool window or a Diff tab.
	console bool
}

// openRollback asks for confirmation before changes of the project's repository are rolled
// back, as the Commit tool window and the Diff tabs ask.
func (a *App) openRollback(p *project, changes []core.GitChange) {
	a.openRollbackIn(p, p.git.repositoryRoot(p.root), changes)
	if p.review.rollback.open {
		p.review.rollback.console = true
	}
}

// openRollbackIn asks for confirmation before changes of the checkout at root are rolled back.
func (a *App) openRollbackIn(p *project, root string, changes []core.GitChange) {
	if _, ok := a.reviewKernel(); !ok || len(changes) == 0 {
		return
	}
	p.review.rollback = rollbackState{open: true, root: root, changes: changes}
}

// runRollback has Core plan the rollback of the confirmed changes, runs its steps in order,
// stops at the first failure and reads the status again whatever happened.
func (a *App) runRollback(p *project) {
	r := &p.review.rollback
	kernel, ok := a.reviewKernel()
	if !ok || r.busy {
		return
	}
	r.busy = true
	changes, deleteAdded, root := r.changes, r.deleteAdded, r.root
	a.performed("git.rollback", surfaceButton)
	if r.console {
		a.showGitConsole(itemCommit)
	}
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		steps, err := kernel.GitRollbackPrepare(ctx, root, changes, deleteAdded)
		for i := 0; err == nil && i < len(steps); i++ {
			err = kernel.GitRunRollbackStep(ctx, root, steps[i])
		}
		return func(a *App) {
			p.review.rollback = rollbackState{}
			a.checkoutWritten(p, root)
			a.reloadDiffs(p, root)
			if err != nil {
				a.reviewFailed("git_rollback", err)
			}
		}
	})
}
