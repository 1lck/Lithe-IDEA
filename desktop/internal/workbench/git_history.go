package workbench

import (
	"context"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// This file runs the history actions of the log's commit menu (matrix id git-history-rewrite).
// Undo Commit, Edit Commit Message, Drop Commit and Squash Commits are reviewed: a dialog shows
// the preview Core makes of the rewrite, every commit whose identity changes and the message an
// edit or a squash takes, and the write runs only against that unchanged preview. Cherry-Pick and
// Revert Commit are confirmed first and run once Core found no local change they would
// overwrite; Reset Current Branch to Here asks for its mode. A merge, cherry-pick, revert or
// rebase Git holds active, also one started outside Lithe, is shown on the Commit tool window
// with the controls Core accepts for it. The rules are Core's; this file only asks and shows.
// The menu, the dialogs and the banner are declared in git_history_view.go.

// historyKernel is the part of the kernel the history actions use. *core.Client implements it.
type historyKernel interface {
	GitHistoryActionCapabilities(ctx context.Context, root string, revisions []string) (core.HistoryActionCapabilities, error)
	GitHistoryRewritePreview(ctx context.Context, root, operation string, revisions []string) (core.HistoryRewritePreview, error)
	GitHistoryRewrite(ctx context.Context, root string, preview core.HistoryRewritePreview, message string) (*core.HistoryRewriteResult, []core.GitWarning, error)
	GitCherryPick(ctx context.Context, root, revision string) error
	GitRevert(ctx context.Context, root, revision string) error
	GitReset(ctx context.Context, root, revision string, mode core.GitResetMode) error
	GitOperationState(ctx context.Context, root string) (core.GitOperation, error)
	GitOperationControl(ctx context.Context, root, control string) error
	GitIntegrationPreflight(ctx context.Context, root, operation, reference string) (core.IntegrationPreflight, error)
}

// The operations Git holds active, as git.operationState names them.
const (
	gitOperationRebase     = "rebase"
	gitOperationMerge      = "merge"
	gitOperationCherryPick = "cherryPick"
	gitOperationRevert     = "revert"
)

// historyState is the history actions of a project: the dialogs of a rewrite, a reset and a
// cherry-pick or revert, the hints of the commit menu, and the operation Git holds active.
type historyState struct {
	rewrite historyRewriteState
	reset   historyResetState
	confirm historyConfirmState
	// integrate is the confirmation of a merge, rebase or pull the reference menu asked for.
	integrate historyIntegrateState
	// hintsKey names the repository, the history load and the commits hints are for; hintsGen
	// counts the requests, so only the newest answer is kept. hintsReady says it arrived.
	hintsKey   string
	hintsGen   int
	hintsReady bool
	hints      core.HistoryActionCapabilities
	// operation is what Git holds active in operationRoot, the repository a cherry-pick, a
	// revert or a reset last ran in, empty for the project's own one.
	operation     core.GitOperation
	operationRoot string
	operationGen  int
	// busy says a cherry-pick, a revert, a reset or a control of the operation is running.
	busy bool
}

// historyRewriteState is the dialog of one reviewed history rewrite.
type historyRewriteState struct {
	open bool
	// gen counts the dialogs opened; an answer for an older one is dropped.
	gen       int
	busy      bool
	operation string
	revisions []string
	// root is the repository the log walked when the dialog opened, where the rewrite acts.
	root    string
	preview core.HistoryRewritePreview
	loaded  bool
	message ui.Field
	err     string
	// stale says the last write was refused before it changed anything, so the preview is
	// spent and only a new review may be written.
	stale bool
	// recovery is what Core reported of a write that failed after it made the recovery point;
	// the preview is spent then, and the dialog only shows where the old history is kept.
	recovery *core.HistoryRewriteResult
	list     ui.ListState
}

// historyResetState is the dialog of Reset Current Branch to Here.
type historyResetState struct {
	open     bool
	revision string
	root     string
	mode     core.GitResetMode
}

// historyConfirmState is the dialog that confirms a cherry-pick or a revert of one commit.
type historyConfirmState struct {
	open bool
	// operation is gitOperationCherryPick or gitOperationRevert.
	operation string
	revision  string
	subject   string
	root      string
}

// historyResetModes are the modes the reset dialog offers, in the order it shows them.
var historyResetModes = []core.GitResetMode{core.GitResetSoft, core.GitResetMixed, core.GitResetHard}

// historyOperationRoot is the repository whose active operation the Commit tool window shows.
func (p *project) historyOperationRoot() string {
	if p.gitHistory.operationRoot != "" {
		return p.gitHistory.operationRoot
	}
	return p.git.repositoryRoot(p.root)
}

// historyBusy reports that a history action or a rebase is running, so no other may start.
func (p *project) historyBusy() bool {
	return p.gitHistory.busy || p.gitHistory.rewrite.busy || p.rebase.busy
}

// logMenuRevisions are the commits the commit menu of row acts on: the commits chosen in the
// list, newest first as it shows them, when row is one of several chosen, else row's commit.
func (a *App) logMenuRevisions(p *project, row int) []string {
	v, rows := &a.logView, p.log.graph.Rows
	if row < 0 || row >= len(rows) {
		return nil
	}
	if v.chosen.Len() < 2 || !v.commits.Chosen(row) {
		return []string{rows[row].CommitHash}
	}
	revisions := make([]string, 0, v.chosen.Len())
	for i := range rows {
		if v.commits.Chosen(i) && len(revisions) < core.MaxHistorySelection {
			revisions = append(revisions, rows[i].CommitHash)
		}
	}
	return revisions
}

// historyHints are Core's hints for the commit menu of revisions in the repository the log walks.
// The first call for a selection asks for them and reports nothing ready; the menu is painted
// again when they arrive. A failed request offers every action, and the action's own preview or
// write decides.
func (a *App) historyHints(p *project, revisions []string) (core.HistoryActionCapabilities, bool) {
	h := &p.gitHistory
	root := p.logRepositoryRoot()
	key := root + "\x00" + strconv.Itoa(p.log.gen) + "\x00" + strings.Join(revisions, ",")
	if h.hintsKey == key {
		return h.hints, h.hintsReady
	}
	h.hintsKey, h.hintsReady, h.hints = key, false, core.HistoryActionCapabilities{}
	kernel, ok := a.kernel.(historyKernel)
	if !ok {
		return h.hints, false
	}
	h.hintsGen++
	gen := h.hintsGen
	asked := append([]string(nil), revisions...)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		hints, err := kernel.GitHistoryActionCapabilities(core.AutomaticRefresh(ctx), root, asked)
		return func(a *App) {
			h := &p.gitHistory
			if h.hintsGen != gen || h.hintsKey != key {
				return
			}
			if err != nil {
				hints = core.HistoryActionCapabilities{CanCherryPick: true, CanUndo: true, CanSquash: true}
			}
			h.hints, h.hintsReady = hints, true
		}
	})
	return h.hints, false
}

// copyRevisions puts the hashes of revisions on the clipboard, short when short says so, one per
// line. label names the menu item, for the notice of a failure.
func (a *App) copyRevisions(revisions []string, short bool, label string) {
	if short {
		a.performed("git.log.copyShortHash", surfaceMenu)
	} else {
		a.performed("git.log.copyCommitHash", surfaceMenu)
	}
	hashes := make([]string, len(revisions))
	for i, revision := range revisions {
		hashes[i] = revision
		if short {
			hashes[i] = shortHash(revision)
		}
	}
	if err := app.SetClipboardText(strings.Join(hashes, "\n")); err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "git.log.copyFailed", map[string]string{"label": label}))
	}
}

// beginTagAt opens the New Tag dialog on the commit revision of the repository the log walks.
func (a *App) beginTagAt(p *project, revision string) {
	a.adoptLogBranches(p)
	a.beginCreateTag(p)
	a.branch.target = core.GitReference{FullName: revision, ShortName: shortHash(revision)}
}

// beginHistoryRewrite opens the dialog of the rewrite operation of revisions and reads its preview.
func (a *App) beginHistoryRewrite(p *project, operation string, revisions []string) {
	a.reviewHistoryRewrite(p, operation, revisions, p.logRepositoryRoot())
	a.performed("git.history."+operation, surfaceMenu)
}

// reviewHistoryRewrite opens the rewrite dialog of operation on revisions in root and reads its
// preview; it also reloads the review of a dialog whose preview is spent.
func (a *App) reviewHistoryRewrite(p *project, operation string, revisions []string, root string) {
	kernel, ok := a.kernel.(historyKernel)
	if !ok || len(revisions) == 0 {
		return
	}
	r := &p.gitHistory.rewrite
	gen := r.gen + 1
	asked := append([]string(nil), revisions...)
	message := r.message.Text()
	*r = historyRewriteState{open: true, gen: gen, busy: true, operation: operation, revisions: asked, root: root}
	// A reload keeps the message the user was writing; a new dialog takes Core's suggestion.
	r.message.SetText(message)
	keep := r.message.Text() != "" && historyTakesMessage(operation)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitHistoryRewritePreview(ctx, root, operation, asked)
		return func(a *App) {
			r := &p.gitHistory.rewrite
			if !r.open || r.gen != gen {
				return
			}
			r.busy, r.loaded = false, true
			if err != nil {
				r.err = reviewReason(err)
				a.gitOperationFailed("git_history_preview", err)
				return
			}
			r.preview = preview
			if historyTakesMessage(operation) && !keep {
				r.message.SetText(preview.SuggestedMessage)
			}
		}
	})
}

// historyTakesMessage reports that the rewrite operation writes a message the user edits.
func historyTakesMessage(operation string) bool {
	return operation == core.HistoryEditCommitMessage || operation == core.HistorySquashCommits
}

// historyRewritable reports that the open dialog's preview may be written now.
func (r *historyRewriteState) historyRewritable() bool {
	if r.busy || !r.loaded || r.stale || r.recovery != nil || !r.preview.Allowed || len(r.preview.ExpectedState) == 0 {
		return false
	}
	return !historyTakesMessage(r.operation) || strings.TrimSpace(r.message.Text()) != ""
}

// closeHistoryRewrite closes the rewrite dialog and drops the preview it waits for. A write that
// is running finishes; its outcome is still notified.
func (a *App) closeHistoryRewrite(p *project) {
	r := &p.gitHistory.rewrite
	r.open = false
	if !r.busy {
		r.gen++
	}
}

// reloadHistoryRewrite reads the preview of the open dialog again after a write was refused.
func (a *App) reloadHistoryRewrite(p *project) {
	r := &p.gitHistory.rewrite
	if !r.open || r.busy {
		return
	}
	a.reviewHistoryRewrite(p, r.operation, r.revisions, r.root)
}

// runHistoryRewrite writes the reviewed preview of the open dialog. The message is sent as the
// user left it; Core validates it without trimming.
func (a *App) runHistoryRewrite(p *project) {
	kernel, ok := a.kernel.(historyKernel)
	r := &p.gitHistory.rewrite
	if !ok || !r.historyRewritable() {
		return
	}
	preview, root, gen, operation := r.preview, r.root, r.gen, r.operation
	message := ""
	if historyTakesMessage(operation) {
		message = r.message.Text()
	}
	r.busy, r.err = true, ""
	a.performed("git.history."+operation+".write", surfaceButton)
	a.showGitConsole(root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		result, warnings, err := kernel.GitHistoryRewrite(ctx, root, preview, message)
		return func(a *App) {
			r := &p.gitHistory.rewrite
			current := r.gen == gen
			if current {
				r.busy = false
			}
			lang := a.language()
			// Core's warnings are its own diagnostics, shown as it words them.
			for _, warning := range warnings {
				a.notifyInfo(warning.Message)
			}
			switch {
			case err == nil:
				if current {
					r.open = false
				}
				if result != nil && result.WorktreeRefresh == "failed" {
					a.notifyError(i18n.Shared(lang, "git.historyReview.refreshFailed"))
				} else {
					a.notifySuccess(i18n.Shared(lang, "git.historyReview.completed"))
				}
			case result != nil:
				// The recovery point exists, so the history may have changed: the dialog keeps
				// it in reach and the preview is not offered again.
				if current && r.open {
					r.recovery, r.err = result, reviewReason(err)
				} else {
					a.notifyError(historyRecoveryNotice(lang, result))
				}
				a.gitOperationFailed("git_history_write", err)
			default:
				// Nothing changed; the preview is spent and has to be read again.
				if current && r.open {
					r.err, r.stale = reviewReason(err), true
				} else {
					a.notifyError(i18n.SharedFormat(lang, "git.operationError", map[string]string{"error": reviewReason(err)}))
				}
				a.gitOperationFailed("git_history_write", err)
				return
			}
			a.afterHistoryWrite(p, root)
		}
	})
}

// historyRecoveryOutcome says what a write that failed after its recovery point left.
func historyRecoveryOutcome(lang i18n.Language, result *core.HistoryRewriteResult) string {
	switch {
	case !result.OutcomeKnown:
		return i18n.Shared(lang, "git.historyReview.outcomeUnknown")
	case result.MutationApplied && result.WorktreeRefresh == "failed":
		return i18n.Shared(lang, "git.historyReview.refreshFailed")
	case result.MutationApplied:
		return i18n.Shared(lang, "git.historyReview.failed")
	default:
		return i18n.Shared(lang, "git.historyReview.reviewAgain")
	}
}

// historyRecoveryNotice is the notice of a failed write whose dialog was closed: what it left and
// where the old history is kept.
func historyRecoveryNotice(lang i18n.Language, result *core.HistoryRewriteResult) string {
	return historyRecoveryOutcome(lang, result) + " " +
		i18n.SharedFormat(lang, "native.recoveryReference", map[string]string{"arg1": result.RecoveryReference})
}

// copyRecoveryReference puts the recovery reference of the dialog's failed write on the clipboard.
func (a *App) copyRecoveryReference(p *project) {
	result := p.gitHistory.rewrite.recovery
	if result == nil {
		return
	}
	a.performed("git.history.copyRecovery", surfaceButton)
	lang := a.language()
	if err := app.SetClipboardText(result.RecoveryReference); err != nil {
		a.notifyError(i18n.Shared(lang, "git.historyReview.copyFailed"))
		return
	}
	a.notifyInfo(i18n.Shared(lang, "git.historyReview.copied"))
}

// beginCherryPick opens the dialog that confirms the cherry-pick or the revert, as operation
// says, of the commit revision in the repository the log walks.
func (a *App) beginCherryPick(p *project, operation, revision string) {
	if _, ok := a.kernel.(historyKernel); !ok {
		return
	}
	commit, _ := p.log.commit(revision)
	p.gitHistory.confirm = historyConfirmState{open: true, operation: operation, revision: revision, subject: commit.Subject, root: p.logRepositoryRoot()}
}

// runCherryPick applies the change of the confirmed commit on the current branch, or reverts it,
// once Core found no local change in the way. A stop at conflicts leaves the operation active,
// and the Commit tool window shows it.
func (a *App) runCherryPick(p *project) {
	kernel, ok := a.kernel.(historyKernel)
	h := &p.gitHistory
	if !ok || p.historyBusy() || !h.confirm.open {
		return
	}
	confirm := h.confirm
	h.confirm.open, h.busy = false, true
	operation, revision, root := confirm.operation, confirm.revision, confirm.root
	a.performed("git.log."+operation, surfaceButton)
	a.showGitConsole(root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		preflight, err := kernel.GitIntegrationPreflight(ctx, root, operation, revision)
		blocked := err == nil && len(preflight.BlockingPaths) > 0
		if err == nil && !blocked {
			if operation == gitOperationRevert {
				err = kernel.GitRevert(ctx, root, revision)
			} else {
				err = kernel.GitCherryPick(ctx, root, revision)
			}
		}
		return func(a *App) {
			p.gitHistory.busy = false
			lang := a.language()
			switch {
			case blocked:
				a.notifyError(i18n.SharedFormat(lang, "git.log.operationBlocked", map[string]string{"paths": historyPathList(preflight.BlockingPaths)}))
				return
			case err != nil:
				a.notifyError(i18n.SharedFormat(lang, "git.operationError", map[string]string{"error": reviewReason(err)}))
				a.gitOperationFailed("git_"+operation, err)
			case operation == gitOperationRevert:
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.gitHistory.reverted", map[string]string{"hash": shortHash(revision)}))
			default:
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.gitHistory.cherryPicked", map[string]string{"hash": shortHash(revision)}))
			}
			a.afterHistoryWrite(p, root)
		}
	})
}

// historyPathList is the first few of paths, for a notice.
func historyPathList(paths []string) string {
	const shown = 3
	if len(paths) <= shown {
		return strings.Join(paths, ", ")
	}
	return strings.Join(paths[:shown], ", ") + ", …"
}

// beginHistoryReset opens the reset dialog on revision, with the mixed mode Git takes by default.
func (a *App) beginHistoryReset(p *project, revision string) {
	if _, ok := a.kernel.(historyKernel); !ok {
		return
	}
	p.gitHistory.reset = historyResetState{open: true, revision: revision, root: p.logRepositoryRoot(), mode: core.GitResetMixed}
}

// runHistoryReset moves the current branch to the commit of the reset dialog in its mode.
func (a *App) runHistoryReset(p *project) {
	kernel, ok := a.kernel.(historyKernel)
	h := &p.gitHistory
	if !ok || p.historyBusy() || !h.reset.open {
		return
	}
	reset := h.reset
	h.reset.open, h.busy = false, true
	a.performed("git.log.reset", surfaceButton)
	a.showGitConsole(reset.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		err := kernel.GitReset(ctx, reset.root, reset.revision, reset.mode)
		return func(a *App) {
			p.gitHistory.busy = false
			lang := a.language()
			if err != nil {
				a.notifyError(i18n.SharedFormat(lang, "git.operationError", map[string]string{"error": reviewReason(err)}))
				a.gitOperationFailed("git_reset", err)
			} else {
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.gitHistory.resetDone", map[string]string{"hash": shortHash(reset.revision)}))
			}
			a.afterHistoryWrite(p, reset.root)
		}
	})
}

// loadGitOperation reads the operation Git holds active in the background, so a cherry-pick
// that stopped at conflicts, or a merge started in a terminal, is shown with its controls.
func (a *App) loadGitOperation(p *project) {
	kernel, ok := a.kernel.(historyKernel)
	if !ok || !p.git.isRepository() {
		return
	}
	h := &p.gitHistory
	h.operationGen++
	gen, root := h.operationGen, p.historyOperationRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		// The state is read on every repository change, too often for the console.
		state, err := kernel.GitOperationState(core.AutomaticRefresh(ctx), root)
		return func(a *App) {
			h := &p.gitHistory
			if err != nil || h.operationGen != gen {
				return
			}
			h.operation = state
			// With nothing active in another repository, the window shows the project's own again.
			if state.Kind == "" && h.operationRoot != "" {
				h.operationRoot = ""
				a.loadGitOperation(p)
			}
		}
	})
}

// historyOperationShown reports that the Commit tool window shows the banner of the operation Git
// holds active: a rebase Lithe runs has its own banner (git_rebase_view.go).
func (p *project) historyOperationShown() bool {
	kind := p.gitHistory.operation.Kind
	if kind == "" {
		return false
	}
	if kind == gitOperationRebase {
		s := p.rebase.session
		if s != nil && !rebaseDone(s.Status) && p.rebaseRoot() == p.historyOperationRoot() {
			return false
		}
	}
	return true
}

// controlGitOperation continues, skips or aborts the operation Git holds active.
func (a *App) controlGitOperation(p *project, control string) {
	kernel, ok := a.kernel.(historyKernel)
	h := &p.gitHistory
	if !ok || p.historyBusy() || h.operation.Kind == "" {
		return
	}
	root := p.historyOperationRoot()
	h.busy = true
	a.performed("git."+control, surfaceButton)
	a.showGitConsole(root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		err := kernel.GitOperationControl(ctx, root, control)
		return func(a *App) {
			p.gitHistory.busy = false
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "git.operationError", map[string]string{"error": reviewReason(err)}))
				a.gitOperationFailed("git_"+control, err)
			}
			a.afterHistoryWrite(p, root)
		}
	})
}

// afterHistoryWrite reads the status, the active operation of root and the log again after a
// history action moved HEAD or the index of the repository root.
func (a *App) afterHistoryWrite(p *project, root string) {
	if root != p.git.repositoryRoot(p.root) {
		p.gitHistory.operationRoot = root
	}
	a.loadGit(p)
	if p.log.started {
		a.loadLog(p)
	}
}
