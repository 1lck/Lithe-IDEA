package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// This file holds the Worktrees tab of the Git tool window: the worktrees registered with the
// project's repository, the local changes and the history of the selected one, and the writes
// that add, remove, lock, prune and repair them. The page and its dialogs are declared in
// gitworktree_view.go.

const (
	// worktreeListWidth is the width the worktree list starts with; worktreeListMin and
	// worktreeDetailsMin are the least the list and the details keep while the splitter moves.
	worktreeListWidth  = 300
	worktreeListMin    = 220
	worktreeDetailsMin = 320
	// worktreeHistoryPage is the number of commits the History tab reads at a time.
	worktreeHistoryPage = 100
	// worktreeLoadMoreMargin is how near the end of the history the list is scrolled when the
	// next page is read.
	worktreeLoadMoreMargin = 200
)

// worktreeDialog is the dialog of the Worktrees tab that is open over the window.
type worktreeDialog uint8

const (
	worktreeDialogNone worktreeDialog = iota
	worktreeDialogCreate
	worktreeDialogRemove
	// worktreeDialogReview shows why Git refused to remove a checkout with changes and offers
	// the forced removal.
	worktreeDialogReview
	worktreeDialogForce
	worktreeDialogPrune
)

// worktreeTab is a tab of the details of the selected worktree.
type worktreeTab uint8

const (
	worktreeTabOverview worktreeTab = iota
	worktreeTabChanges
	worktreeTabHistory
)

// worktreeTabs are the details' tabs in the order they are shown.
var worktreeTabs = []worktreeTab{worktreeTabOverview, worktreeTabChanges, worktreeTabHistory}

// The modes a worktree can be created in, in the order the dialog offers them.
var worktreeModes = []string{core.GitWorktreeNewBranch, core.GitWorktreeExistingBranch, core.GitWorktreeDetached}

// worktreeAfterCreate is what the window does once a worktree was created.
type worktreeAfterCreate uint8

const (
	worktreeStay worktreeAfterCreate = iota
	worktreeOpenAfter
)

// worktreeAfterChoices are the choices of worktreeAfterCreate in the order they are offered.
var worktreeAfterChoices = []worktreeAfterCreate{worktreeStay, worktreeOpenAfter}

// worktreeChanges is the local changes of one worktree, read when its Changes tab is shown.
// A reading again keeps the changes read before on show until it answers; busy is set while
// a staging write runs.
type worktreeChanges struct {
	loading bool
	busy    bool
	err     error
	changes []core.GitChange
}

// worktreeHistory is the commits reachable from the HEAD of the worktree at path, read a page
// at a time. gen tells the answer of a walk that was given up from the current one.
type worktreeHistory struct {
	path                string
	gen                 int
	loading, loaded     bool
	loadingMore, failed bool
	err                 error
	commits             []core.GitCommit
	// graph is the lanes of commits as the Log tab lays them out; remotes and current are the
	// repository's remote branch names and the worktree's branch, read with the first page,
	// which tell its labels apart.
	graph   core.Graph
	remotes []string
	current string
	// cursor continues the walk; it is open in Core until the walk reaches its end or the
	// history is given up, which closes it.
	cursor string
}

// worktreeCreation is the state of the dialog that creates a worktree.
type worktreeCreation struct {
	mode string
	// refs are the repository's references, read when the dialog opens.
	refs       core.GitReferences
	refsLoaded bool
	refsErr    error
	// kind is the kind of reference the dialog lists: "local", "remote" or "tag". An
	// existing-branch worktree lists local branches only.
	kind string
	// reference is the FullName of the chosen reference, empty for none.
	reference string
	name      ui.Field
	revision  ui.Field
	// destination is the path of the new checkout. Core keeps it on the suggestion the inputs
	// make for as long as it holds the last one, suggested, that is until the user edits it.
	destination ui.Field
	suggested   string
	// result is Core's preview of the inputs: the references to choose from, the cleaned and
	// checked branch name, the destination and whether the worktree can be created. key is the
	// inputs it was made for, so it is made again only when they change.
	result     core.GitWorktreeCreationPreview
	key        worktreeCreationKey
	noCheckout bool
	after      worktreeAfterCreate
}

// worktreeCreationKey is what a creation preview is made from: the dialog's inputs, whether
// the references were read, and the reading of the list that tells which branches are
// checked out.
type worktreeCreationKey struct {
	mode, kind, reference       string
	name, revision, destination string
	refsLoaded                  bool
	listGen                     int
}

// inputs is the key of a preview of the dialog's inputs as they stand; gen is the reading of
// the worktree list.
func (cr *worktreeCreation) inputs(gen int) worktreeCreationKey {
	return worktreeCreationKey{
		mode: cr.mode, kind: cr.kind, reference: cr.reference,
		name: cr.name.Text(), revision: cr.revision.Text(), destination: cr.destination.Text(),
		refsLoaded: cr.refsLoaded, listGen: gen,
	}
}

// worktreeState is a project's Worktrees tab: the registered worktrees, their changes and the
// open dialog.
type worktreeState struct {
	started, loading, loaded bool
	err                      error
	// gen counts the readings of the list, so the answer of one that was overtaken is dropped.
	gen  int
	list []core.GitWorktree
	// counts are the numbers of local changes of the worktrees by path, and statuses the
	// states Core derived with them; a worktree whose status could not be read has neither.
	// countGen tells the answer of a count that a later one overtook.
	counts      map[string]int
	statuses    map[string]string
	countsKnown bool
	countGen    int
	selected    string
	changes     map[string]*worktreeChanges
	// commits are the commits of the linked worktrees by path, each with its own message,
	// kept while the project is open; the project's own checkout commits with the Commit
	// tool window (see worktreeCommit).
	commits map[string]*commitState
	history worktreeHistory
	dialog  worktreeDialog
	// target is the worktree a removal dialog asks about; refusal is what Git said when it
	// refused to remove it without force.
	target  core.GitWorktree
	refusal string
	busy    bool
	create  worktreeCreation
}

// find returns the worktree registered at path.
func (w *worktreeState) find(path string) (core.GitWorktree, bool) {
	for _, worktree := range w.list {
		if worktree.Path == path {
			return worktree, true
		}
	}
	return core.GitWorktree{}, false
}

// stale is the number of registrations whose checkout is gone.
func (w *worktreeState) stale() int {
	n := 0
	for _, worktree := range w.list {
		if worktree.IsPrunable {
			n++
		}
	}
	return n
}

// worktreeView is the window's state of the Worktrees tab that is not the project's: the
// splitter, the search fields, the lists and the chosen tab.
type worktreeView struct {
	split        ui.SplitterState
	search       ui.Field
	commitSearch ui.Field
	list         ui.ListState
	commits      ui.ListState
	tab          worktreeTab
	// shown is the commits the History tab lists, the search applied, and graphed says they
	// are the history's commits in its order, which the lanes of the graph belong to.
	shown   []core.GitCommit
	graphed bool
	// slotRow is the row each draw slot of the History tab paints and painters the slots'
	// callbacks, made once per slot so painting allocates nothing.
	slotRow  [logRowSlots]int
	painters [logRowSlots]func(*ui.DrawContext)
	// hashWidth is the width of the short hash column in the fonts of hashFonts.
	hashWidth float32
	hashFonts uint32
	// commit is the splitter between the Changes tab's list and its commit area.
	commit commitView
}

// reset empties the fields and the lists for a project that was just opened.
func (v *worktreeView) reset() {
	v.search.SetText("")
	v.commitSearch.SetText("")
	v.list = ui.ListState{}
	v.commits = ui.ListState{}
	v.tab = worktreeTabOverview
	v.shown, v.graphed = nil, false
}

// worktreeName is how a prompt or a notice names a worktree: its branch, or the folder of its
// checkout.
func worktreeName(w core.GitWorktree) string {
	if w.Branch != "" {
		return strings.TrimPrefix(w.Branch, "refs/heads/")
	}
	return filepath.Base(w.Path)
}

// statusOf is the state w's row shows, which Core derives: with its counted local changes once
// they are, from its registration alone before.
func (ws *worktreeState) statusOf(w core.GitWorktree) string {
	if status, ok := ws.statuses[w.Path]; ok {
		return status
	}
	return w.Status
}

// worktreeReasonText words why Core refuses or blocks a worktree write, empty for a code that
// is not such a reason. removing says the write is a removal, whose refusal of the primary
// worktree and of a missing checkout reads differently from a lock's.
func worktreeReasonText(t *i18n.WorktreeMessages, removing bool, code core.ErrorCode) string {
	switch code {
	case core.CodeGitWorktreePrimary:
		if removing {
			return t.RemovePrimary
		}
		return t.LockPrimary
	case core.CodeGitWorktreeCurrent:
		return t.RemoveCurrent
	case core.CodeGitWorktreeLocked:
		return t.RemoveLocked
	case core.GitWorktreeBlockedMissing:
		if removing {
			return t.RemovePrunable
		}
		return t.LockPrunable
	}
	return ""
}

// worktreeRemoveBlocked is why w cannot be removed, as Core gave it, empty when it can.
func worktreeRemoveBlocked(t *i18n.WorktreeMessages, w core.GitWorktree) string {
	if w.Actions.Remove.Allowed {
		return ""
	}
	return worktreeReasonText(t, true, w.Actions.Remove.Reason)
}

// worktreeLockBlocked is why the lock of w cannot be changed, as Core gave it, empty when it
// can.
func worktreeLockBlocked(t *i18n.WorktreeMessages, w core.GitWorktree) string {
	if w.Actions.Lock.Allowed {
		return ""
	}
	return worktreeReasonText(t, false, w.Actions.Lock.Reason)
}

// worktreeFailureText words the failure of a worktree write for the user. Core names each
// refusal with its own code, so the words come from the code, never from the message; a
// failure without one of those codes is shown with what Git or Core said. removing says the
// write was a removal.
func worktreeFailureText(t *i18n.WorktreeMessages, removing bool, err error) string {
	var e *core.Error
	if errors.As(err, &e) {
		if text := worktreeReasonText(t, removing, e.Code); text != "" {
			return text
		}
		if e.Message != "" {
			return t.Failed(e.Message)
		}
	}
	return t.Failed(err.Error())
}

// worktreeErrorCode is the code of a Core error in err, empty for another error.
func worktreeErrorCode(err error) core.ErrorCode {
	var e *core.Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

// chosenReference is the loaded reference the dialog chose.
func (cr *worktreeCreation) chosenReference() (core.GitReference, bool) {
	if cr.reference == "" {
		return core.GitReference{}, false
	}
	for _, r := range cr.refs.References {
		if r.FullName == cr.reference {
			return r, true
		}
	}
	return core.GitReference{}, false
}

// worktreeReferenceKinds are the kinds of reference the dialog can start from, in the order
// it offers them.
var worktreeReferenceKinds = []string{"local", "remote", "tag"}

// checkedOutBranches are the full names of the branches the worktrees in list have checked
// out, which an existing-branch worktree cannot check out again.
func checkedOutBranches(list []core.GitWorktree) []string {
	branches := make([]string, 0, len(list))
	for _, w := range list {
		if w.Branch != "" {
			branches = append(branches, w.Branch)
		}
	}
	return branches
}

// loadWorktrees reads the worktrees of p's repository again, then the number of local changes
// of each. The selection stays on its path while that is registered, else it moves to the
// current worktree.
func (a *App) loadWorktrees(p *project) {
	w := &p.worktrees
	w.started, w.loading = true, true
	w.gen++
	gen := w.gen
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		list, err := kernel.GitWorktrees(ctx, root)
		return func(a *App) {
			w := &p.worktrees
			if w.gen != gen {
				return
			}
			w.loading, w.loaded, w.err = false, true, err
			if err != nil {
				w.list = nil
				a.gitOperationFailed("git_worktrees", err)
				return
			}
			w.list = list
			for path, cs := range w.commits {
				if _, ok := w.find(path); !ok && !cs.busy && cs.review == nil {
					delete(w.commits, path) // a removed worktree's message goes with it
				}
			}
			if _, ok := w.find(w.selected); !ok {
				w.selected = ""
				for _, worktree := range list {
					if worktree.IsCurrent {
						w.selected = worktree.Path
					}
				}
			}
			// A write may have changed every checkout, so what was read of them is read again.
			w.changes = nil
			a.dropWorktreeHistory(p)
			w.countsKnown = false
			a.countWorktreeChanges(p, gen)
		}
	})
}

// countWorktreeChanges has Core count the local changes of every worktree that has a
// checkout and derive the states that follow from them, in one listing. gen is the reading of
// the list the counts belong to; the counts known before stay on show until the answer.
func (a *App) countWorktreeChanges(p *project, gen int) {
	w := &p.worktrees
	w.countGen++
	countGen := w.countGen
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		counted, err := kernel.GitWorktreesWithChanges(core.AutomaticRefresh(ctx), root)
		return func(a *App) {
			w := &p.worktrees
			if w.gen != gen || w.countGen != countGen {
				return
			}
			counts, statuses := make(map[string]int, len(counted)), make(map[string]string, len(counted))
			if err == nil {
				for _, worktree := range counted {
					if worktree.Changes != nil {
						counts[worktree.Path], statuses[worktree.Path] = *worktree.Changes, worktree.Status
					}
				}
			}
			w.counts, w.statuses, w.countsKnown = counts, statuses, true
		}
	})
}

// selectWorktree shows the details of the worktree at path.
func (a *App) selectWorktree(p *project, path string) {
	w := &p.worktrees
	if w.selected == path {
		return
	}
	w.selected = path
	a.worktreeView.commitSearch.SetText("")
	a.worktreeView.commits = ui.ListState{}
	a.dropWorktreeHistory(p)
}

// loadWorktreeChanges reads the local changes of the worktree at path for its Changes tab.
func (a *App) loadWorktreeChanges(p *project, path string) {
	w := &p.worktrees
	if w.changes == nil {
		w.changes = map[string]*worktreeChanges{}
	}
	entry := &worktreeChanges{loading: true}
	if old := w.changes[path]; old != nil && old.err == nil {
		entry.changes = old.changes
	}
	w.changes[path] = entry
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		status, err := kernel.GitStatus(ctx, path)
		return func(a *App) {
			if p.worktrees.changes[path] != entry {
				return
			}
			entry.loading, entry.err, entry.changes = false, err, status.Changes
			w := &p.worktrees
			if known, ok := w.counts[path]; err == nil && (!ok || known != len(status.Changes)) {
				if w.counts == nil {
					w.counts = map[string]int{}
				}
				// The count shows at once; the state that follows from it is Core's to derive
				// again.
				w.counts[path] = len(status.Changes)
				a.countWorktreeChanges(p, w.gen)
			}
		}
	})
}

// stageWorktreeChange stages or unstages one change of the worktree at path, as a click on
// its checkbox asks; it follows the change list of the commit panel.
func (a *App) stageWorktreeChange(p *project, path string, change core.GitChange) {
	entry := p.worktrees.changes[path]
	if entry == nil || entry.busy || entry.loading || !change.CanToggleStaging {
		return
	}
	stage, paths := stagesChange(change), change.StagingPaths()
	if stage {
		a.performed("git.worktree.stage", surfaceButton)
	} else {
		a.performed("git.worktree.unstage", surfaceButton)
	}
	a.writeWorktreeStaging(p, path, entry, stage, func(ctx context.Context, kernel Kernel) error {
		if stage {
			return kernel.GitStage(ctx, path, paths)
		}
		return kernel.GitUnstage(ctx, path, paths)
	})
}

// stageAllWorktree stages every change of the worktree at path, or unstages every staged one
// when everything is staged already.
func (a *App) stageAllWorktree(p *project, path string) {
	entry := p.worktrees.changes[path]
	if entry == nil || entry.busy || entry.loading || !hasToggleable(entry.changes) {
		return
	}
	if allStaged(entry.changes) {
		paths := stagedPaths(entry.changes)
		a.performed("git.worktree.unstageAll", surfaceButton)
		a.writeWorktreeStaging(p, path, entry, false, func(ctx context.Context, kernel Kernel) error {
			return kernel.GitUnstage(ctx, path, paths)
		})
		return
	}
	a.performed("git.worktree.stageAll", surfaceButton)
	a.writeWorktreeStaging(p, path, entry, true, func(ctx context.Context, kernel Kernel) error {
		return kernel.GitStageAll(ctx, path)
	})
}

// writeWorktreeStaging runs a staging write in the worktree at path and reads what it changed
// again, telling the user when it failed.
func (a *App) writeWorktreeStaging(p *project, path string, entry *worktreeChanges, stage bool, write func(context.Context, Kernel) error) {
	entry.busy = true
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel)
		return func(a *App) {
			entry.busy = false
			a.checkoutWritten(p, path)
			if err != nil {
				a.stagingFailed(stage, err)
			}
		}
	})
}

// projectCheckout says the worktree at path is the checkout the project is open in, as Core
// marked it in the list, which names checkouts by their canonical paths.
func (p *project) projectCheckout(path string) bool {
	w, ok := p.worktrees.find(path)
	return ok && w.IsCurrent
}

// worktreeCommit is the commit of the worktree at path. The project's own checkout commits
// as the Commit tool window does, with its message and held to its active ChangeList; a
// linked worktree has a message of its own and commits all it has staged. A run in one reads
// the list of worktrees again, since its HEAD moved.
func (p *project) worktreeCommit(path string) commitTarget {
	if p.projectCheckout(path) {
		return p.projectCommit()
	}
	w := &p.worktrees
	cs := w.commits[path]
	if cs == nil {
		if w.commits == nil {
			w.commits = map[string]*commitState{}
		}
		state := newCommitState()
		cs = &state
		w.commits[path] = cs
	}
	return commitTarget{
		state: cs,
		root:  path,
		written: func(a *App) {
			a.loadWorktrees(p)
			if p.log.started {
				a.loadLog(p)
			}
		},
	}
}

// canCommitWorktree reports that the commit buttons of the linked worktree at path may start
// a commit: its changes were read, something is staged, there is a message, and no other
// commit work or staging write is under way.
func (p *project) canCommitWorktree(path string, cs *commitState) bool {
	entry := p.worktrees.changes[path]
	return entry != nil && !entry.busy && !entry.loading && entry.err == nil &&
		cs.idle() && countStaged(entry.changes) > 0 && cs.message() != ""
}

// checkoutWritten reads again what a write in the checkout at root changed: the project's
// status, and the changes of the worktree at root when its Changes tab read them.
func (a *App) checkoutWritten(p *project, root string) {
	a.loadGit(p)
	if root == p.git.repositoryRoot(p.root) {
		// The list names the project's checkout by its canonical path, which a symbolic link
		// in the project's path makes another.
		for _, w := range p.worktrees.list {
			if w.IsCurrent {
				root = w.Path
			}
		}
	}
	if p.worktrees.changes[root] != nil {
		a.loadWorktreeChanges(p, root)
	}
}

// loadWorktreeHistory reads the first page of the history of the worktree at path.
func (a *App) loadWorktreeHistory(p *project, path string) {
	a.dropWorktreeHistory(p)
	h := &p.worktrees.history
	h.path, h.loading = path, true
	a.readWorktreeHistory(p, "")
}

// loadMoreWorktreeHistory reads the next page of the history when there is one and none is
// on its way.
func (a *App) loadMoreWorktreeHistory(p *project) {
	h := &p.worktrees.history
	if h.cursor == "" || h.loading || h.loadingMore || h.failed {
		return
	}
	h.loadingMore = true
	a.readWorktreeHistory(p, h.cursor)
}

// readWorktreeHistory reads the page of the history that cursor continues, from the start for
// an empty cursor. A page that comes back after the history was given up has its cursor
// closed.
func (a *App) readWorktreeHistory(p *project, cursor string) {
	h := &p.worktrees.history
	gen, path, kernel := h.gen, h.path, a.kernel
	// known is cut to its length so the background append copies it instead of writing into
	// the array the window thread keeps appending to.
	known, remotes, current, expanded := h.commits[:len(h.commits):len(h.commits)], h.remotes, h.current, p.log.expanded
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		if cursor == "" {
			if _, sections, branch, err := readReferences(ctx, kernel, path); err == nil {
				remotes, current = remoteNames(sections), branch
			}
		}
		page, err := kernel.GitHistoryPage(ctx, path, "HEAD", cursor, worktreeHistoryPage)
		var graph core.Graph
		var graphErr error
		if err == nil {
			commits := graphCommits(append(known, page.Commits...))
			graph, graphErr = kernel.GitGraph(ctx, core.GraphRequest{
				Commits: commits, RemoteNames: remotes, RepositoryCommits: commits,
				Expanded: expanded, CurrentBranch: current,
			})
		}
		return func(a *App) {
			h := &p.worktrees.history
			if h.gen != gen {
				if err == nil && page.NextCursor != "" {
					a.closeWorktreeCursor(p, path, page.NextCursor)
				}
				return
			}
			first := cursor == ""
			h.loading, h.loadingMore = false, false
			if err != nil {
				if first {
					h.err = err
				} else {
					h.failed = true
				}
				a.gitOperationFailed("git_worktree_history", err)
				return
			}
			h.loaded = true
			h.commits = append(h.commits, page.Commits...)
			h.cursor = page.NextCursor
			h.remotes, h.current, h.graph = remotes, current, graph
			if graphErr != nil {
				// The commits still show, without their lanes.
				a.gitOperationFailed("git_worktree_graph", graphErr)
			}
		}
	})
}

// dropWorktreeHistory gives up the history that was read, closing its open cursor.
func (a *App) dropWorktreeHistory(p *project) {
	h := &p.worktrees.history
	if h.cursor != "" {
		a.closeWorktreeCursor(p, h.path, h.cursor)
	}
	*h = worktreeHistory{gen: h.gen + 1}
}

// closeWorktreeCursor releases a history cursor of the worktree at path.
func (a *App) closeWorktreeCursor(p *project, path, cursor string) {
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		_, _ = kernel.CloseGitHistoryCursor(ctx, path, cursor)
		return nil
	})
}

// runWorktreeWrite runs write against p's repository in the background. On success the
// dialog closes, done runs, and the worktrees, the log and the status are read again. A
// failure is worded by worktreeFailureText unless refused takes it; a path the list showed but
// Git no longer knows makes the list be read again.
func (a *App) runWorktreeWrite(p *project, operation string, removing bool,
	write func(ctx context.Context, kernel Kernel, root string) error, refused func(a *App, err error) bool, done func(a *App)) {
	w := &p.worktrees
	w.busy = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, branchOperationTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root)
		return func(a *App) {
			w := &p.worktrees
			w.busy = false
			if err != nil {
				if refused != nil && refused(a, err) {
					return
				}
				w.dialog = worktreeDialogNone
				a.notifyError(worktreeFailureText(&a.text.Worktrees, removing, err))
				a.gitOperationFailed(operation, err)
				if worktreeErrorCode(err) == core.CodeGitWorktreeNotRegistered {
					a.loadWorktrees(p)
				}
				return
			}
			w.dialog = worktreeDialogNone
			if done != nil {
				done(a)
			}
			if a.project != p {
				return
			}
			a.loadWorktrees(p)
			if p.log.started {
				a.loadLog(p)
			}
			a.refreshChanges(p)
		}
	})
}

// toggleWorktreeLock locks w, or unlocks it when it is locked.
func (a *App) toggleWorktreeLock(p *project, w core.GitWorktree) {
	if w.IsLocked {
		a.performed("git.worktree.unlock", surfaceButton)
		a.runWorktreeWrite(p, "git_worktree_unlock", false, func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitUnlockWorktree(ctx, root, w.Path)
		}, nil, nil)
		return
	}
	a.performed("git.worktree.lock", surfaceButton)
	a.runWorktreeWrite(p, "git_worktree_lock", false, func(ctx context.Context, kernel Kernel, root string) error {
		return kernel.GitLockWorktree(ctx, root, w.Path)
	}, nil, nil)
}

// beginRemoveWorktree asks whether to remove w.
func (a *App) beginRemoveWorktree(p *project, w core.GitWorktree) {
	a.performed("git.worktree.remove", surfaceButton)
	p.worktrees.dialog, p.worktrees.target, p.worktrees.refusal = worktreeDialogRemove, w, ""
}

// removeWorktree removes the dialog's worktree; force removes it with its local changes. Git's
// refusal of a checkout with changes opens the review that offers the forced removal.
func (a *App) removeWorktree(p *project, force bool) {
	target := p.worktrees.target
	operation := "git_worktree_remove"
	if force {
		operation = "git_worktree_remove_force"
	}
	a.runWorktreeWrite(p, operation, true, func(ctx context.Context, kernel Kernel, root string) error {
		return kernel.GitRemoveWorktree(ctx, root, target.Path, force)
	}, func(a *App, err error) bool {
		var e *core.Error
		if force || !errors.As(err, &e) || e.Code != core.CodeGitWorktreeHasChanges {
			return false
		}
		p.worktrees.dialog, p.worktrees.refusal = worktreeDialogReview, e.Message
		return true
	}, func(a *App) {
		a.notifySuccess(a.text.Worktrees.Removed(worktreeName(target)))
	})
}

// pruneWorktrees removes the registrations whose checkouts are gone.
func (a *App) pruneWorktrees(p *project) {
	a.runWorktreeWrite(p, "git_worktree_prune", false, func(ctx context.Context, kernel Kernel, root string) error {
		return kernel.GitPruneWorktrees(ctx, root)
	}, nil, func(a *App) { a.notifySuccess(a.text.Worktrees.Pruned) })
}

// repairWorktrees repairs the links between the repository and its worktrees.
func (a *App) repairWorktrees(p *project) {
	a.performed("git.worktree.repair", surfaceButton)
	a.runWorktreeWrite(p, "git_worktree_repair", false, func(ctx context.Context, kernel Kernel, root string) error {
		return kernel.GitRepairWorktrees(ctx, root)
	}, nil, func(a *App) { a.notifySuccess(a.text.Worktrees.Repaired) })
}

// revealWorktree shows the checkout at path in the system's file browser.
func (a *App) revealWorktree(path string) {
	a.performed("git.worktree.reveal", surfaceButton)
	a.background(nil, 0, func(context.Context) func(*App) {
		err := app.RevealPath(path)
		return func(a *App) {
			if err != nil {
				a.gitOperationFailed("git_worktree_reveal", err)
				a.notifyError(a.text.Worktrees.Failed(err.Error()))
			}
		}
	})
}

// copyWorktreePath puts the path of a checkout on the clipboard.
func (a *App) copyWorktreePath(path string) {
	a.performed("git.worktree.copyPath", surfaceButton)
	if err := app.SetClipboardText(path); err != nil {
		a.notifyError(a.text.Worktrees.Failed(err.Error()))
	}
}

// showWorktrees opens the Git tool window on its Worktrees tab, as the Git tools menu asks.
func (a *App) showWorktrees() {
	a.performed("git.worktrees.show", surfaceMenu)
	a.layout.gitTab = gitTabWorktrees
	if !a.chrome.isOpen(catalogIndex[itemGit]) {
		a.reduceChrome(core.SetChromeOpen(itemGit, true))
	}
}

// openWorktree opens the checkout at path as the window's project.
func (a *App) openWorktree(path string) {
	a.performed("git.worktree.open", surfaceButton)
	// The worktree menu offers This Window and New Window itself.
	a.openProjectThisWindow(path)
}

// beginCreateWorktree opens the dialog that creates a worktree and reads the references it
// can start from.
func (a *App) beginCreateWorktree(p *project) {
	a.performed("git.worktree.create", surfaceButton)
	w := &p.worktrees
	cr := &w.create
	cr.mode, cr.kind, cr.refs, cr.refsLoaded, cr.refsErr, cr.reference = core.GitWorktreeNewBranch, "local", core.GitReferences{}, false, nil, ""
	cr.name.SetText("")
	cr.revision.SetText("")
	cr.destination.SetText("")
	cr.suggested, cr.result, cr.key, cr.noCheckout, cr.after = "", core.GitWorktreeCreationPreview{}, worktreeCreationKey{}, false, worktreeStay
	w.dialog = worktreeDialogCreate
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		refs, err := kernel.GitReferences(ctx, root)
		return func(a *App) {
			cr := &p.worktrees.create
			if p.worktrees.dialog != worktreeDialogCreate || cr.refsLoaded {
				return
			}
			cr.refs, cr.refsErr, cr.refsLoaded = refs, err, true
			if err != nil {
				a.gitOperationFailed("git_worktree_references", err)
			}
			a.syncWorktreeCreation(p)
		}
	})
}

// syncWorktreeCreation keeps the dialog's derived values in step with its inputs, asking Core
// again whenever they changed: the reference stays one the mode can use, the branch name is
// cleaned and checked as the user types, and the destination follows the suggestion until the
// user edits it.
func (a *App) syncWorktreeCreation(p *project) {
	if cr := &p.worktrees.create; cr.inputs(p.worktrees.gen) != cr.key {
		a.previewWorktreeCreation(p, false)
	}
}

// previewWorktreeCreation has Core derive the dialog's values from its inputs and applies
// them; require makes an empty branch name an error, as a submit does. It reports whether Core
// answered; without an answer the dialog cannot create the worktree.
func (a *App) previewWorktreeCreation(p *project, require bool) bool {
	w := &p.worktrees
	cr := &w.create
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.GitWorktreeCreationPreview(ctx, core.GitWorktreeCreationInput{
		Root: p.git.repositoryRoot(p.root), Mode: cr.mode, Kind: cr.kind, Reference: cr.reference,
		Name: cr.name.Text(), RequireName: require, Revision: cr.revision.Text(),
		Destination: cr.destination.Text(), LastSuggestion: cr.suggested,
		References: cr.refs.References, CheckedOutBranches: checkedOutBranches(w.list),
	})
	if err != nil {
		a.gitOperationFailed("git_worktree_creation_preview", err)
		cr.result.Ready = false
		cr.key = cr.inputs(w.gen)
		return false
	}
	cr.result = result
	if cr.refsLoaded {
		cr.reference = ""
		if result.Reference != nil {
			cr.reference = *result.Reference
		}
	}
	if b := result.Branch; b != nil && b.TypingCleanedName != cr.name.Text() {
		cr.name.SetText(b.TypingCleanedName)
	}
	if result.Destination != cr.destination.Text() {
		cr.destination.SetText(result.Destination)
	}
	cr.suggested = result.SuggestedDestination
	cr.key = cr.inputs(w.gen)
	return true
}

// submitCreateWorktree creates the worktree the dialog describes, once Core confirms, with the
// branch name required, that it can be created.
func (a *App) submitCreateWorktree(p *project) {
	cr := &p.worktrees.create
	if p.worktrees.busy || !cr.result.Ready || !a.previewWorktreeCreation(p, true) || !cr.result.Ready {
		return
	}
	creation := core.GitWorktreeCreation{
		Mode:        cr.mode,
		Destination: filepath.Clean(strings.TrimSpace(cr.destination.Text())),
		NoCheckout:  cr.noCheckout,
	}
	name := filepath.Base(creation.Destination)
	if b := cr.result.Branch; cr.mode == core.GitWorktreeNewBranch && b != nil {
		creation.Name, name = b.CleanedName, b.CleanedName
	}
	if r, ok := cr.chosenReference(); ok {
		creation.Reference = &r
		if cr.mode == core.GitWorktreeExistingBranch {
			name = r.ShortName
		}
	}
	if cr.mode != core.GitWorktreeExistingBranch {
		creation.Revision = strings.TrimSpace(cr.revision.Text())
	}
	openAfter := cr.after == worktreeOpenAfter
	a.performed("git.worktree.createSubmit", surfaceButton)
	a.runWorktreeWrite(p, "git_worktree_create", false, func(ctx context.Context, kernel Kernel, root string) error {
		return kernel.GitCreateWorktree(ctx, root, creation)
	}, nil, func(a *App) {
		a.notifySuccess(a.text.Worktrees.Created(name))
		// Git lists the checkout by its canonical path, which differs from the typed one under
		// a symbolic link.
		selected := creation.Destination
		if resolved, err := filepath.EvalSymlinks(selected); err == nil {
			selected = resolved
		}
		p.worktrees.selected = selected
		if openAfter {
			a.openProject(creation.Destination)
		}
	})
}

// cancelWorktreeDialog closes the open dialog of the Worktrees tab.
func (a *App) cancelWorktreeDialog() {
	if p := a.project; p != nil && !p.worktrees.busy {
		p.worktrees.dialog = worktreeDialogNone
	}
}
