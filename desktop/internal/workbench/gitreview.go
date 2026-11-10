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
// window and the Git menu open: the Diff dialog with block staging and rollback, the Push
// dialog, the stash, worktree and repository tools, the blame annotations and the listing of a
// summarized untracked directory. Core decides everything about Git (which blocks exist, which
// destination a push goes to, what a rollback runs); this file sequences the calls and keeps
// what the dialogs show. gitreview_diff_view.go and gitreview_tools_view.go declare the
// dialogs.

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
	GitWorktrees(ctx context.Context, root string) ([]core.GitWorktree, error)
	GitCreateWorktree(ctx context.Context, root string, creation core.GitWorktreeCreation) error
	GitRemoveWorktree(ctx context.Context, root, path string, force bool) error
	GitLockWorktree(ctx context.Context, root, path string) error
	GitUnlockWorktree(ctx context.Context, root, path string) error
	GitPruneWorktrees(ctx context.Context, root string) error
	GitPushPreviewOf(ctx context.Context, root string, branch core.GitReference, tags core.GitPushTags, target core.PushTargetChoice) (core.GitPushPreview, error)
	GitPush(ctx context.Context, root string, preview core.GitPushPreview, tags core.GitPushTags, target core.PushTargetChoice, force bool) error
	DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error)
}

// reviewKernel is the window's kernel as the review dialogs use it.
func (a *App) reviewKernel() (gitReviewKernel, bool) {
	k, ok := a.kernel.(gitReviewKernel)
	return k, ok
}

// gitReview is the state of a project's review dialogs. It is reset when the project closes.
type gitReview struct {
	diff      diffState
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
	a.notify(i18n.SharedFormat(a.language(), "desktop.gitReview.operationFailed", map[string]string{"reason": reviewReason(err)}))
	a.gitOperationFailed(operation, err)
}

// --- Diff ---

// diffState is the open Diff dialog: which change it shows, the file's lines and rows, and the
// blocks Core planned for staging and rolling them back.
type diffState struct {
	open    bool
	loading bool
	// gen counts the loads; the answer of an older one is dropped.
	gen    int
	err    string
	change core.GitChange
	// staged says the dialog shows the index against HEAD, for a change that is only staged.
	staged bool
	// split shows the two sides next to each other instead of the unified lines.
	split bool
	file  *core.GitDiffFile
	plan  *core.DiffBlockPlan
	// items is what the list shows, built from file and plan.
	items []diffItem
	list  ui.ListState
	// busy is set while a block is written.
	busy bool
	// confirm is the block waiting for the user to confirm its rollback, "" for none.
	confirm string
	// note is a refusal to show: the plan went stale, or a rollback is unsafe.
	note string
}

// diffItem is one row of the Diff list: a line of the file, or the header of a block that
// carries its toggle and rollback.
type diffItem struct {
	// block is the block a header row belongs to; zero for a line row.
	block *core.DiffBlock
	// number is the 1-based position of the block among the blocks.
	number int
	// line indexes the unified lines, row the aligned rows.
	line, row int
}

// openDiff opens the Diff dialog on change and reads it in the background.
func (a *App) openDiff(p *project, change core.GitChange) {
	if _, ok := a.reviewKernel(); !ok || strings.HasSuffix(change.Path, "/") {
		return
	}
	d := &p.review.diff
	*d = diffState{open: true, loading: true, gen: d.gen + 1, change: change, split: d.split, list: d.list}
	d.staged = change.Staged && !change.Worktree
	a.performed("git.diff.open", surfaceMenu)
	a.loadDiff(p)
}

// closeDiff closes the dialog and forgets what it showed.
func (a *App) closeDiff(p *project) {
	d := &p.review.diff
	d.open, d.file, d.plan, d.items, d.confirm, d.note = false, nil, nil, nil, "", ""
	d.gen++
}

// diffTarget is the file of the open dialog as Core's block commands take it.
func (d *diffState) target(root string) core.DiffBlockTarget {
	return core.DiffBlockTarget{Root: root, Path: d.change.Path, OriginalPath: d.change.OriginalPath, Staged: d.staged}
}

// loadDiff reads the diff of the dialog's change again: the block plan for a tracked file, and
// the plain diff for an untracked one or a file the plan has no section for.
func (a *App) loadDiff(p *project) {
	d := &p.review.diff
	kernel, ok := a.reviewKernel()
	if !ok {
		return
	}
	d.loading = true
	gen, change, target := d.gen, d.change, d.target(p.git.repositoryRoot(p.root))
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		var (
			file *core.GitDiffFile
			plan *core.DiffBlockPlan
			err  error
		)
		if !change.Untracked && change.Status != "??" {
			var got core.DiffBlockPlan
			if got, err = kernel.PlanDiffBlocks(ctx, target); err == nil {
				plan = &got
				if got.Worktree != nil && len(got.Worktree.Files) > 0 {
					file = &got.Worktree.Files[0]
				}
			}
		}
		if err == nil && file == nil {
			plan = nil
			var files []core.GitDiffFile
			files, err = kernel.GitDiff(ctx, core.GitDiffRequest{Root: target.Root, Path: change.Path, Staged: target.Staged, Untracked: change.Untracked || change.Status == "??"})
			if err == nil && len(files) > 0 {
				file = &files[0]
			}
		}
		return func(a *App) {
			d := &p.review.diff
			if !d.open || d.gen != gen {
				return
			}
			d.loading = false
			if err != nil {
				d.err = i18n.SharedFormat(a.language(), "git.diff.getFileDiffFailed", map[string]string{"file": change.Path, "error": reviewReason(err)})
				a.gitOperationFailed("git_diff", err)
				return
			}
			d.err, d.file, d.plan = "", file, plan
			d.rebuild()
		}
	})
}

// rebuild lays out the list rows for the current mode: each block's header stands over its
// first line.
func (d *diffState) rebuild() {
	d.items = d.items[:0]
	if d.file == nil {
		return
	}
	starts := map[int]*core.DiffBlock{}
	if d.plan != nil {
		for i := range d.plan.Blocks {
			if n, ok := blockLine(d.plan.Blocks[i].ID); ok {
				starts[n] = &d.plan.Blocks[i]
			}
		}
	}
	number := 0
	if d.split {
		anchors := map[int]*core.DiffBlock{}
		for n, block := range starts {
			if row, ok := d.rowOfLine(n); ok {
				anchors[row] = block
			}
		}
		for row := range d.file.Rows {
			if block, ok := anchors[row]; ok {
				number++
				d.items = append(d.items, diffItem{block: block, number: number, row: row, line: -1})
			}
			d.items = append(d.items, diffItem{row: row, line: -1})
		}
		return
	}
	for i := range d.file.Lines {
		if block, ok := starts[i]; ok {
			number++
			d.items = append(d.items, diffItem{block: block, number: number, line: i, row: -1})
		}
		d.items = append(d.items, diffItem{line: i, row: -1})
	}
}

// blockLine is the unified-line index a block ID names ("line-<index>").
func blockLine(id string) (int, bool) {
	rest, ok := strings.CutPrefix(id, "line-")
	if !ok || rest == "" {
		return 0, false
	}
	n := 0
	for _, r := range rest {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}

// rowOfLine finds the aligned row that shows unified line index, by the line numbers they
// share.
func (d *diffState) rowOfLine(index int) (int, bool) {
	if d.file == nil || index < 0 || index >= len(d.file.Lines) {
		return 0, false
	}
	line := d.file.Lines[index]
	for i, row := range d.file.Rows {
		switch {
		case line.NewLine != nil && row.NewLine != nil && *line.NewLine == *row.NewLine:
			return i, true
		case line.NewLine == nil && line.OldLine != nil && row.OldLine != nil && *line.OldLine == *row.OldLine:
			return i, true
		}
	}
	return 0, false
}

// toggleDiffBlock stages the block, or unstages it when it is staged.
func (a *App) toggleDiffBlock(p *project, block core.DiffBlock) {
	action := core.DiffBlockInclude
	if block.Checked {
		action = core.DiffBlockExclude
	}
	a.writeDiffBlock(p, block.ID, action)
}

// writeDiffBlock applies one action to a block of the plan the dialog shows. A plan that went
// stale is read again, so the user reviews the file as it is now.
func (a *App) writeDiffBlock(p *project, id string, action core.DiffBlockAction) {
	d := &p.review.diff
	kernel, ok := a.reviewKernel()
	if !ok || d.busy || d.plan == nil {
		return
	}
	d.busy, d.confirm, d.note = true, "", ""
	gen, plan, target := d.gen, *d.plan, d.target(p.git.repositoryRoot(p.root))
	a.performed("git.diff.block."+string(action), surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		err := kernel.ApplyDiffBlock(ctx, plan, target, id, action)
		return func(a *App) {
			d := &p.review.diff
			a.loadGit(p)
			if !d.open || d.gen != gen {
				return
			}
			d.busy = false
			if err != nil {
				a.diffBlockRefused(p, err)
			}
			a.loadDiff(p)
		}
	})
}

// diffBlockRefused tells the user why Core refused a block write and logs it.
func (a *App) diffBlockRefused(p *project, err error) {
	d := &p.review.diff
	switch text := err.Error() + " " + reviewReason(err); {
	case strings.Contains(text, "GIT_DIFF_BLOCK_STALE"), strings.Contains(text, "GIT_DIFF_BLOCK_UNAVAILABLE"):
		d.note = i18n.Shared(a.language(), "git.diff.hunkStale")
	case strings.Contains(text, "GIT_HUNK_ROLLBACK_UNSAFE"):
		d.note = i18n.Shared(a.language(), "git.diff.rollbackUnsafe")
	default:
		d.note = i18n.Shared(a.language(), "git.diff.stageFailed")
	}
	a.gitOperationFailed("git_diff_block", err)
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
	open        bool
	busy        bool
	changes     []core.GitChange
	deleteAdded bool
}

// openRollback asks for confirmation before changes are rolled back.
func (a *App) openRollback(p *project, changes []core.GitChange) {
	if _, ok := a.reviewKernel(); !ok || len(changes) == 0 {
		return
	}
	p.review.rollback = rollbackState{open: true, changes: changes}
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
	changes, deleteAdded, root := r.changes, r.deleteAdded, p.git.repositoryRoot(p.root)
	a.performed("git.rollback", surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		steps, err := kernel.GitRollbackPrepare(ctx, root, changes, deleteAdded)
		for i := 0; err == nil && i < len(steps); i++ {
			err = kernel.GitRunRollbackStep(ctx, root, steps[i])
		}
		return func(a *App) {
			p.review.rollback = rollbackState{}
			a.loadGit(p)
			if p.review.diff.open {
				a.loadDiff(p)
			}
			if err != nil {
				a.reviewFailed("git_rollback", err)
			}
		}
	})
}
