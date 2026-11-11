package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the commit menu of the log, the dialogs of its history actions and the
// banner of the operation Git holds active. State and the calls are in git_history.go.

// historyRewriteMenuOperations are the reviewed rewrites, in the order the commit menu shows them.
var historyRewriteMenuOperations = []string{core.HistoryUndoCommit, core.HistoryEditCommitMessage, core.HistorySquashCommits, core.HistoryDeleteCommit}

// historyRewriteMenuText is the commit menu item of the rewrite operation.
func historyRewriteMenuText(lang i18n.Language, operation string) string {
	switch operation {
	case core.HistoryUndoCommit:
		return i18n.Shared(lang, "desktop.gitHistory.undoCommit")
	case core.HistoryEditCommitMessage:
		return i18n.Shared(lang, "native.editCommitMessage.variant2")
	case core.HistorySquashCommits:
		return i18n.Shared(lang, "native.squashCommits.variant2")
	default:
		return i18n.Shared(lang, "desktop.gitHistory.deleteCommit")
	}
}

// logCommitMenu declares the commit menu of log row: copying the hashes of the commits it acts
// on, a tag, a cherry-pick, a revert or a reset at one commit, the reviewed rewrites, and Rebase
// from Here. Core's hints only grey out what cannot fit the selection; the dialogs decide.
func (a *App) logCommitMenu(p *project, row int) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		revisions := a.logMenuRevisions(p, row)
		if len(revisions) == 0 {
			return
		}
		lang := a.language()
		single, revision := len(revisions) == 1, revisions[0]
		busy := p.historyBusy()
		hints, ready := a.historyHints(p, revisions)
		for _, short := range []bool{false, true} {
			label := i18n.Shared(lang, "git.log.copyCommitHash")
			if short {
				label = i18n.Shared(lang, "git.log.copyShortHash")
			}
			if menu.Item(label).Clicked() {
				a.copyRevisions(revisions, short, label)
			}
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "git.log.newTag")).Disabled(!single).Clicked() {
			a.beginTagAt(p, revision)
		}
		// Until the hints arrive a cherry-pick stays offered, as its preflight still decides.
		if menu.Item(i18n.Shared(lang, "native.cherryPickCommit")).Disabled(!single || busy || ready && !hints.CanCherryPick).Clicked() {
			a.beginCherryPick(p, gitOperationCherryPick, revision)
		}
		if menu.Item(i18n.Shared(lang, "native.revertCommit")).Disabled(!single || busy).Clicked() {
			a.beginCherryPick(p, gitOperationRevert, revision)
		}
		if menu.Item(i18n.Shared(lang, "native.resetCurrentBranchToHere")).Disabled(!single || busy).Clicked() {
			a.beginHistoryReset(p, revision)
		}
		menu.Separator()
		for _, operation := range historyRewriteMenuOperations {
			item := menu.Item(historyRewriteMenuText(lang, operation))
			if operation == core.HistoryDeleteCommit {
				item = item.Destructive()
			}
			if item.Disabled(busy || !historyRewriteFits(operation, single, ready, hints)).Clicked() {
				a.beginHistoryRewrite(p, operation, revisions)
			}
		}
		if menu.Item(i18n.Shared(lang, "desktop.rebase.fromHere")).Disabled(!single || busy).Clicked() {
			// The rebase works in the repository the log walks, nested or the project's own.
			a.beginRebaseFromHere(p, revision, "")
		}
	}
}

// historyRewriteFits reports that the menu offers the rewrite operation for its selection:
// undo and squash as Core's hints allow them, which wait for the hints, the others for a single
// commit.
func historyRewriteFits(operation string, single, ready bool, hints core.HistoryActionCapabilities) bool {
	switch operation {
	case core.HistoryUndoCommit:
		return ready && hints.CanUndo
	case core.HistorySquashCommits:
		return ready && hints.CanSquash
	default:
		return single
	}
}

// historyRewriteTitle is the title of the dialog of the rewrite operation.
func historyRewriteTitle(lang i18n.Language, operation string) string {
	switch operation {
	case core.HistoryUndoCommit:
		return i18n.Shared(lang, "git.undoCommit")
	case core.HistoryEditCommitMessage:
		return i18n.Shared(lang, "git.editCommitMessage")
	case core.HistorySquashCommits:
		return i18n.Shared(lang, "git.squashCommits")
	default:
		return i18n.Shared(lang, "git.deleteCommit")
	}
}

// historyRewriteAction is the label of the button that writes the rewrite operation.
func historyRewriteAction(lang i18n.Language, operation string) string {
	if operation == core.HistoryEditCommitMessage {
		return i18n.Shared(lang, "git.saveCommitMessage")
	}
	return historyRewriteTitle(lang, operation)
}

// historyRewriteImpact says what the reviewed rewrite operation of count commits does.
func historyRewriteImpact(lang i18n.Language, operation string, count int) string {
	switch operation {
	case core.HistoryUndoCommit:
		return i18n.Shared(lang, "git.historyReview.undoCommit")
	case core.HistoryEditCommitMessage:
		return i18n.Shared(lang, "git.historyReview.editCommitMessage")
	case core.HistorySquashCommits:
		return i18n.SharedFormat(lang, "git.historyReview.squashCommits", map[string]string{"count": strconv.Itoa(count)})
	default:
		return i18n.Shared(lang, "git.historyReview.deleteCommit")
	}
}

// drawHistoryDialogs declares the dialogs of the history actions that are open.
func (a *App) drawHistoryDialogs(c ui.C, p *project) {
	h := &p.gitHistory
	if h.rewrite.open {
		a.drawHistoryRewriteDialog(c, p)
	}
	if h.confirm.open {
		a.drawHistoryConfirmDialog(c, p)
	}
	if h.reset.open {
		a.drawHistoryResetDialog(c, p)
	}
}

// drawHistoryRewriteDialog declares the review of a rewrite: what it does, the reasons Core
// refuses it, every commit whose identity changes, oldest first, and the message an edit or a
// squash writes. A write that failed after its recovery point shows where the old history is.
func (a *App) drawHistoryRewriteDialog(c ui.C, p *project) {
	r := &p.gitHistory.rewrite
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	open := true
	spec := ui.ModalSpec{Description: i18n.Shared(lang, "git.historyReview.description"), Width: reviewDialogWidth, Height: reviewDialogHeight}
	closed := ui.ModalWith(c, &open, historyRewriteTitle(lang, r.operation), spec, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			if r.err != "" {
				ui.Paragraph(c, r.err, 4).FontSize(size).Color(a.theme.Danger)
			}
			switch {
			case r.recovery != nil:
				a.drawHistoryRecovery(c, p)
			case r.busy && !r.loaded:
				a.gitEmpty(c, i18n.Shared(lang, "git.historyReview.loading"))
			case r.busy:
				a.gitEmpty(c, i18n.Shared(lang, "git.historyReview.running"))
			case !r.loaded:
			case !r.preview.Allowed:
				// Core's reasons are its own diagnostics, shown as it words them.
				for _, blocker := range r.preview.Blockers {
					ui.Paragraph(c, blocker.Message, 3).FontSize(size).Color(a.theme.Danger)
				}
			default:
				a.drawHistoryPreview(c, p)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if r.stale {
			if ui.Button(c, i18n.Shared(lang, "git.historyReview.reload")).Outline().Disabled(r.busy).Clicked() {
				c.After(func() { a.reloadHistoryRewrite(p) })
			}
		}
		if r.recovery != nil {
			if ui.Button(c, i18n.Shared(lang, "git.historyReview.copyRecovery")).Outline().Clicked() {
				c.After(func() { a.copyRecoveryReference(p) })
			}
			return
		}
		apply := ui.Button(c, historyRewriteAction(lang, r.operation)).Disabled(!r.historyRewritable())
		if r.operation == core.HistoryDeleteCommit {
			apply = apply.Destructive()
		}
		if apply.Clicked() {
			c.After(func() { a.runHistoryRewrite(p) })
		}
	})
	if closed || !open {
		c.After(func() { a.closeHistoryRewrite(p) })
	}
}

// drawHistoryPreview declares an allowed preview: what the rewrite does, the commits it rebuilds
// and the message an edit or a squash writes.
func (a *App) drawHistoryPreview(c ui.C, p *project) {
	r := &p.gitHistory.rewrite
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	affected := r.preview.AffectedCommits
	ui.Paragraph(c, historyRewriteImpact(lang, r.operation, len(r.preview.SelectedCommits)), 4).FontSize(size)
	ui.Text(c, i18n.SharedFormat(lang, "git.historyReview.affected", map[string]string{"count": strconv.Itoa(len(affected))})).FontSize(size).Weight(gfx.WeightMedium)
	list := ui.List(c, &r.list, len(affected), func(row ui.ListRow) {
		commit := affected[row.Index]
		row.Element.FillWidth().Height(reviewRowHeight).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Text(row.C, shortHash(commit.Hash)).Mono().FontSize(size).Color(a.colors.Accent).Width(64).Shrink(0)
			ui.Text(row.C, firstLine(commit.Message)).FontSize(size).Ellipsis().Grow(1)
		})
	})
	if !historyTakesMessage(r.operation) {
		list.Grow(1)
		return
	}
	list.Height(float32(min(len(affected), 6)+1) * reviewRowHeight).Shrink(0)
	label := i18n.Shared(lang, "git.log.commitMessage")
	ui.Text(c, label).FontSize(size).Weight(gfx.WeightMedium)
	ui.TextArea(c, &r.message, label, label).FillWidth().Grow(1)
}

// drawHistoryRecovery declares what a write that failed after its recovery point left, and the
// reference that keeps the old history.
func (a *App) drawHistoryRecovery(c ui.C, p *project) {
	result := p.gitHistory.rewrite.recovery
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	ui.Paragraph(c, historyRecoveryOutcome(lang, result), 4).FontSize(size)
	ui.Paragraph(c, i18n.Shared(lang, "git.historyReview.recovery"), 3).FontSize(size).Color(a.colors.Subtle)
	ui.Text(c, i18n.SharedFormat(lang, "native.recoveryReference", map[string]string{"arg1": result.RecoveryReference})).Mono().FontSize(size)
}

// drawHistoryConfirmDialog declares the confirmation of a cherry-pick or a revert.
func (a *App) drawHistoryConfirmDialog(c ui.C, p *project) {
	h := &p.gitHistory
	lang := a.language()
	hash, subject := shortHash(h.confirm.revision), h.confirm.subject
	title := i18n.Shared(lang, "git.cherryPickCommit")
	description := i18n.SharedFormat(lang, "git.cherryPickCommitConfirm", map[string]string{"hash": hash, "message": subject})
	action := i18n.Shared(lang, "native.cherryPick")
	if h.confirm.operation == gitOperationRevert {
		title = i18n.Shared(lang, "git.revertCommit")
		description = i18n.SharedFormat(lang, "git.revertCommitConfirm", map[string]string{"hash": hash, "message": subject})
		action = i18n.Shared(lang, "native.revert")
	}
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Description: description, Width: 460}, nil, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, action).Disabled(p.historyBusy()).Clicked() {
			c.After(func() { a.runCherryPick(p) })
		}
	})
	if closed || !open {
		c.After(func() { h.confirm.open = false })
	}
}

// drawHistoryResetDialog declares the reset of the current branch to a commit, with its mode.
func (a *App) drawHistoryResetDialog(c ui.C, p *project) {
	h := &p.gitHistory
	lang := a.language()
	open := true
	description := i18n.SharedFormat(lang, "git.resetToCommitPrompt", map[string]string{"hash": shortHash(h.reset.revision)})
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "git.resetToCommit"), ui.ModalSpec{Description: description, Width: 460}, func() {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			for _, mode := range historyResetModes {
				button := ui.Button(c, historyResetModeText(lang, mode)).FillWidth()
				if h.reset.mode != mode {
					button = button.Ghost()
				}
				if button.Clicked() {
					c.After(func() { h.reset.mode = mode })
				}
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		reset := ui.Button(c, i18n.Shared(lang, "native.reset")).Disabled(p.historyBusy())
		if h.reset.mode == core.GitResetHard {
			reset = reset.Destructive()
		}
		if reset.Clicked() {
			c.After(func() { a.runHistoryReset(p) })
		}
	})
	if closed || !open {
		c.After(func() { h.reset.open = false })
	}
}

// historyResetModeText is the label of the reset mode.
func historyResetModeText(lang i18n.Language, mode core.GitResetMode) string {
	switch mode {
	case core.GitResetSoft:
		return i18n.Shared(lang, "git.resetSoft")
	case core.GitResetHard:
		return i18n.Shared(lang, "git.resetHard")
	default:
		return i18n.Shared(lang, "git.resetMixed")
	}
}

// drawGitOperationBanner declares the merge, cherry-pick, revert or rebase Git holds active:
// what it is, the step of a rebase, the conflicts left, and continue, skip and abort.
func (a *App) drawGitOperationBanner(c ui.C, p *project) {
	if !p.historyOperationShown() {
		return
	}
	op := p.gitHistory.operation
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	busy := p.historyBusy()
	conflicts := len(op.ConflictedPaths)
	title, resume := historyOperationTexts(lang, op.Kind)
	ui.Column(c).FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
		ui.Text(c, title).FontSize(size).Weight(gfx.WeightMedium)
		if op.Step != nil && op.Total != nil {
			ui.Text(c, i18n.SharedFormat(lang, "git.operationStep", map[string]string{"step": strconv.Itoa(*op.Step), "total": strconv.Itoa(*op.Total)})).FontSize(size).Color(a.colors.Subtle)
		}
		switch {
		case conflicts == 1:
			ui.Paragraph(c, i18n.SharedFormat(lang, "git.conflictedFile", map[string]string{"count": "1"}), 2).FontSize(size).Color(a.theme.Danger)
		case conflicts > 1:
			ui.Paragraph(c, i18n.SharedFormat(lang, "git.conflictedFiles", map[string]string{"count": strconv.Itoa(conflicts)}), 2).FontSize(size).Color(a.theme.Danger)
		default:
			ui.Paragraph(c, i18n.Shared(lang, "git.conflictsResolved"), 2).FontSize(size).Color(a.colors.Subtle)
		}
		ui.Row(c).FillWidth().Gap(6).Children(func() {
			if ui.Button(c, resume).Disabled(busy || conflicts > 0).Clicked() {
				c.After(func() { a.controlGitOperation(p, core.GitOperationContinue) })
			}
			if op.Kind == gitOperationRebase {
				if ui.Button(c, i18n.Shared(lang, "git.skipCommit")).Outline().Disabled(busy).Clicked() {
					c.After(func() { a.controlGitOperation(p, core.GitOperationSkip) })
				}
			}
			if ui.Button(c, i18n.Shared(lang, "git.abort")).Destructive().Outline().Disabled(busy).Clicked() {
				c.After(func() { a.controlGitOperation(p, core.GitOperationAbort) })
			}
		})
	})
	ui.Divider(c)
}

// historyOperationTexts are the banner title and the continue button of the active operation kind.
func historyOperationTexts(lang i18n.Language, kind string) (title, resume string) {
	switch kind {
	case gitOperationMerge:
		return i18n.Shared(lang, "git.mergeInProgress"), i18n.Shared(lang, "git.continueMerge")
	case gitOperationCherryPick:
		return i18n.Shared(lang, "git.cherryPickInProgress"), i18n.Shared(lang, "git.continueCherryPick")
	case gitOperationRevert:
		return i18n.Shared(lang, "git.revertInProgress"), i18n.Shared(lang, "git.continueRevert")
	default:
		return i18n.Shared(lang, "git.rebaseInProgress"), i18n.Shared(lang, "git.continueRebase")
	}
}
