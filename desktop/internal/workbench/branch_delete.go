package workbench

import (
	"context"
	"errors"
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file deletes branches (issue #2184, matrix id git-branches-remotes): one local or remote
// branch from a reference's menu or the Delete button of the log's branches pane, or every branch
// marked in that pane at once. A local branch is deleted with Core's deleteBranch, a remote one
// from its remote with deleteRemoteBranch. Tags have their own dialog (branch_tags.go); the
// current branch and HEAD are never deleted. The dialog is declared in branch_view.go's switch.

// deletableBranch says whether the delete dialog can delete r: any local branch but the checked-out
// one, and any remote branch.
func deletableBranch(r core.GitReference) bool {
	return r.Kind == "local" && !r.IsCurrent || r.Kind == "remote"
}

// beginDelete opens the dialog that confirms deleting the local or remote branch r.
func (a *App) beginDelete(r core.GitReference) { a.beginDeleteBranches([]core.GitReference{r}, 0) }

// beginDeleteBranches opens the dialog that confirms deleting branches, which deletableBranch
// accepts, in that order. skipped counts the marked references left out because they cannot be
// deleted there, which the dialog mentions.
func (a *App) beginDeleteBranches(branches []core.GitReference, skipped int) {
	if len(branches) == 0 {
		return
	}
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target = branchDialogDelete, branches[0]
	b.deleting, b.deleteSkipped = slices.Clone(branches), skipped
	b.deleteGen++
	b.deleteRoot = a.branchRoot(a.project)
	b.deleteUnmerged, b.deleteError = nil, ""
	b.deleteList = ui.ListState{}
	b.deleteResults, b.deleteResultList = nil, ui.ListState{}
}

// logChosenBranches reports whether several rows of the log's branches pane are marked and, when
// they are, the marked branches the delete dialog can delete and how many marked rows it leaves
// out: HEAD, tags and the current branch.
func (a *App) logChosenBranches(p *project) (branches []core.GitReference, skipped int, several bool) {
	refs, head := a.logView.markedLogRefs(p)
	if head {
		skipped = 1
	}
	if len(refs)+skipped < 2 {
		return nil, 0, false
	}
	for _, r := range refs {
		if deletableBranch(r) {
			branches = append(branches, r)
		} else {
			skipped++
		}
	}
	return branches, skipped, true
}

// branchDeletion is how deleting one branch of the dialog ended.
type branchDeletion struct {
	branch core.GitReference
	// target is a deleted local tip, or the unmerged tip Core returned for confirmation.
	target string
	err    error
}

// confirmDelete deletes the branches the delete dialog lists, one after another. A single branch
// that fails keeps the dialog open with Git's reason. Batches retain each outcome, marking only
// failures red; only unmerged local branches enter the separate force confirmation.
func (a *App) confirmDelete(p *project) {
	b := &a.branch
	force := b.dialog == branchDialogForceDelete
	if b.busy || len(b.deleting) == 0 || b.dialog != branchDialogDelete && !force {
		return
	}
	if force && len(b.deleteUnmerged) != len(b.deleting) {
		return
	}
	if b.deleteRoot != a.branchRoot(p) {
		a.operationRejected("git_branch_delete", "repository_changed")
		a.notifyError(i18n.Shared(a.language(), "desktop.branch.deleteRepositoryChanged"))
		a.cancelBranchDialog()
		return
	}
	branches := slices.Clone(b.deleting)
	reviews := slices.Clone(b.deleteUnmerged)
	root, gen := b.deleteRoot, b.deleteGen
	remote := slices.ContainsFunc(branches, func(r core.GitReference) bool { return r.Kind == "remote" })
	timeout := branchOperationTimeout
	if remote {
		// Deleting a remote branch pushes, which waits on the network as a push does.
		timeout = syncTimeout
	}
	action := "git.branch.delete"
	switch {
	case force:
		action = "git.branch.forceDelete"
	case len(branches) > 1:
		action = "git.branch.deleteMany"
	case remote:
		action = "git.branch.deleteRemote"
	}
	a.performed(action, surfaceButton)
	b.busy, b.deleteError = true, ""
	if b.fromPopup {
		a.showGitConsole("")
	}
	kernel := a.kernel
	results := make([]branchDeletion, len(branches))
	a.background(p, timeout, func(ctx context.Context) func(*App) {
		for i, r := range branches {
			if force {
				deleted, err := kernel.GitForceDeleteBranch(ctx, root, r, reviews[i].target)
				results[i] = branchDeletion{branch: r, target: deleted.DeletedTarget, err: err}
			} else {
				results[i] = deleteOneBranch(ctx, kernel, root, r)
			}
		}
		var status core.GitStatus
		var refreshErr error
		var generation uint64
		changed := slices.ContainsFunc(results, func(d branchDeletion) bool { return d.err == nil })
		if changed {
			generation = p.gitStatusGeneration.Add(1)
			status, refreshErr = kernel.GitStatus(core.WithQueryCategory(core.AutomaticRefresh(ctx), core.GitQueryReload), root)
		}
		return func(a *App) {
			for _, d := range results {
				if d.err != nil {
					a.operationFailed("git_branch_delete", d.err)
				}
			}
			if refreshErr != nil {
				a.operationFailed("git_branch_delete_refresh", refreshErr)
			}
			b := &a.branch
			// A late result cannot replace a new dialog or the active repository's view.
			if b.deleteGen != gen {
				return
			}
			b.busy = false
			if root != a.branchRoot(p) {
				a.cancelBranchDialog()
				return
			}
			if changed && refreshErr == nil && root == p.git.repositoryRoot(p.root) {
				if a.setGit(p, gitState{loaded: true, status: status}, generation) {
					a.gitStatusPublished(p)
				}
			}
			a.reportDeletions(p, root, results)
			if refreshErr != nil {
				a.notifyError(a.text.Branch.DeleteFailed(refreshErr.Error()))
			}
			if changed && p.log.started {
				a.loadLog(p)
			}
		}
	})
}

// deleteOneBranch deletes the local or remote branch r in the repository at root.
func deleteOneBranch(ctx context.Context, kernel Kernel, root string, r core.GitReference) branchDeletion {
	if err := ctx.Err(); err != nil {
		return branchDeletion{branch: r, err: err}
	}
	if r.Kind == "remote" {
		return branchDeletion{branch: r, err: kernel.GitDeleteRemoteBranch(ctx, root, r)}
	}
	deleted, err := kernel.GitDeleteBranch(ctx, root, r)
	return branchDeletion{branch: r, target: deleted.DeletedTarget, err: err}
}

// reportDeletions forgets deleted references and offers a separate confirmation only for Core's
// unmerged failures. Marks clear after any successful deletion, so a later Delete cannot reuse them.
func (a *App) reportDeletions(p *project, root string, results []branchDeletion) {
	lang := a.language()
	b := &a.branch
	for _, d := range results {
		i := slices.IndexFunc(b.deleteResults, func(previous branchDeletion) bool { return previous.branch.FullName == d.branch.FullName })
		if i < 0 {
			b.deleteResults = append(b.deleteResults, d)
		} else {
			b.deleteResults[i] = d
		}
	}
	var failed, unmerged []branchDeletion
	for _, d := range b.deleteResults {
		if d.err != nil {
			failed = append(failed, d)
			if review, ok := core.BranchDeleteReview(d.err); ok {
				d.target = review.ExpectedTarget
				unmerged = append(unmerged, d)
			}
			continue
		}
	}
	for _, d := range results {
		if d.err == nil {
			a.dropLogReference(p, root, d.branch.FullName)
		}
	}
	if slices.ContainsFunc(results, func(d branchDeletion) bool { return d.err == nil }) && root == p.logRepositoryRoot() {
		a.logView.forgetLogRefMarks()
	}
	b.dialog, b.deleteError, b.deleteUnmerged = branchDialogNone, "", nil
	if len(unmerged) > 0 {
		b.dialog, b.deleteUnmerged = branchDialogDeleteUnmerged, unmerged
		b.deleting, b.deleteSkipped = nil, 0
		for _, d := range unmerged {
			b.deleting = append(b.deleting, d.branch)
		}
		b.target = b.deleting[0]
		b.deleteList = ui.ListState{}
		return
	} else if len(b.deleteResults) == 1 && len(failed) == 1 {
		b.dialog = branchDialogDelete
		b.deleteError = a.branchDeletionReason(failed[0].err)
	} else if len(failed) > 0 {
		b.dialog = branchDialogDeleteResult
	}
	switch {
	case len(b.deleteResults) == 1 && len(failed) == 1:
		a.notifyError(a.text.Branch.DeleteFailed(b.deleteError))
	case len(failed) > 0:
		first := failed[0]
		a.notifyError(i18n.SharedFormat(lang, "desktop.branch.deleteManyFailed", map[string]string{
			"failed": strconv.Itoa(len(failed)), "total": strconv.Itoa(len(b.deleteResults)),
			"name": first.branch.ShortName, "reason": a.branchDeletionReason(first.err)}))
	case len(results) > 1:
		a.notifySuccess(i18n.SharedFormat(lang, "desktop.branch.deletedMany", map[string]string{"count": strconv.Itoa(len(results))}))
	case results[0].branch.Kind == "remote":
		a.notifySuccess(i18n.SharedFormat(lang, "desktop.branch.deletedRemote", map[string]string{"name": results[0].branch.ShortName}))
	default:
		target := results[0].target
		if len(target) > 10 {
			target = target[:10]
		}
		a.notifySuccess(a.text.Branch.Deleted(results[0].branch.ShortName, target))
	}
}

// branchDeletionReason localizes a stale confirmation and preserves other upstream diagnostics.
func (a *App) branchDeletionReason(err error) string {
	var failure *core.Error
	if errors.As(err, &failure) && failure.Code == core.CodeGitBranchChanged {
		return i18n.Shared(a.language(), "desktop.branch.deleteChanged")
	}
	return err.Error()
}

// drawBranchDeleteDialog declares the dialog that confirms deleting the branches of the session:
// one branch is named in the prompt, several are listed with whether each is local or remote. The
// focus starts on Cancel, the first control, so Enter does not delete by accident.
func (a *App) drawBranchDeleteDialog(c ui.C, p *project) {
	b, t := &a.branch, a.text.Branch
	lang := a.language()
	title, prompt := t.DeleteTitle, ""
	many := len(b.deleting) > 1
	switch {
	case many:
		title = i18n.SharedFormat(lang, "desktop.branch.deleteManyTitle", map[string]string{"count": strconv.Itoa(len(b.deleting))})
	case b.target.Kind == "remote":
		prompt = i18n.SharedFormat(lang, "desktop.branch.deleteRemotePrompt", map[string]string{"name": b.target.ShortName})
	default:
		prompt = t.DeletePrompt(b.target.ShortName)
	}
	body := func() {
		a.drawBranchDeleteList(c, many)
		if b.deleteError != "" {
			ui.Paragraph(c, b.deleteError, 4).Color(a.theme.Danger)
		}
	}
	a.branchDialogOf(c, title, prompt, body, func() {
		if ui.Button(c, t.Cancel).Outline().Disabled(b.busy).AutoFocus().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, t.DeleteButton).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() { a.confirmDelete(p) })
		}
	})
}

// drawBranchForceDeleteDialog separates the failed safe deletion from the destructive
// confirmation. A new modal identity resets focus to Cancel before force can run.
func (a *App) drawBranchForceDeleteDialog(c ui.C, p *project) {
	b, lang := &a.branch, a.language()
	c = c.Part(strconv.Itoa(int(b.dialog)))
	confirming := b.dialog == branchDialogForceDelete
	title := i18n.Shared(lang, "desktop.branch.unmergedTitle")
	prompt := i18n.Shared(lang, "desktop.branch.unmergedPrompt")
	button := i18n.Shared(lang, "desktop.branch.reviewForceDelete")
	result := b.dialog == branchDialogDeleteResult
	if result {
		title = i18n.Shared(lang, "desktop.branch.deleteResultTitle")
		prompt = ""
	}
	if confirming {
		title = i18n.Shared(lang, "desktop.branch.forceDeleteTitle")
		prompt = i18n.Shared(lang, "desktop.branch.forceDeletePrompt")
		button = i18n.Shared(lang, "desktop.branch.forceDelete")
	}
	a.branchDialogOf(c, title, prompt, func() {
		if confirming {
			a.drawBranchDeleteRows(c)
		} else {
			a.drawBranchDeletionResults(c)
		}
	}, func() {
		label := a.text.Branch.Cancel
		if result {
			label = i18n.Shared(lang, "ui.close")
		}
		if ui.Button(c, label).Outline().Disabled(b.busy).AutoFocus().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if !result && ui.Button(c, button).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() {
				if confirming {
					a.confirmDelete(p)
				} else {
					a.performed("git.branch.reviewForceDelete", surfaceButton)
					b.dialog = branchDialogForceDelete
				}
			})
		}
	})
}

// drawBranchDeleteRows virtualizes the selection in either confirmation dialog.
func (a *App) drawBranchDeleteRows(c ui.C) {
	b, g := &a.branch, a.text.Git
	height := min(branchBlockingHeight, float32(len(b.deleting))*28)
	ui.List(c, &b.deleteList, len(b.deleting), func(row ui.ListRow) {
		r := b.deleting[row.Index]
		kind := g.LocalGroup
		if r.Kind == "remote" {
			kind = g.RemoteGroup
		}
		row.Element.FillWidth().Height(28).Gap(8).Items(ui.Center).Children(func() {
			name := ui.Text(row.C, r.ShortName).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			if b.dialog == branchDialogForceDelete {
				name.Color(a.theme.Danger)
			}
			ui.Text(row.C, kind).Shrink(0).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	}).Scrollbars().FillWidth().Height(height)
}

// drawBranchDeletionResults retains the original selection's outcomes. Failed names are red and
// each status exposes its own reason, including failures outside the force-delete selection.
func (a *App) drawBranchDeletionResults(c ui.C) {
	b, lang := &a.branch, a.language()
	deleted := 0
	for _, d := range b.deleteResults {
		if d.err == nil {
			deleted++
		}
	}
	ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.branch.deleteResultSummary", map[string]string{
		"deleted": strconv.Itoa(deleted), "kept": strconv.Itoa(len(b.deleteResults) - deleted)}), 3)
	height := min(branchBlockingHeight, float32(len(b.deleteResults))*28)
	ui.List(c, &b.deleteResultList, len(b.deleteResults), func(row ui.ListRow) {
		d := b.deleteResults[row.Index]
		status, reason := i18n.Shared(lang, "desktop.branch.deleteResultDeleted"), ""
		color := a.colors.Text
		if d.err != nil {
			color = a.theme.Danger
			status, reason = i18n.Shared(lang, "desktop.branch.deleteResultFailed"), a.branchDeletionReason(d.err)
			if _, ok := core.BranchDeleteReview(d.err); ok {
				status = i18n.Shared(lang, "desktop.branch.deleteResultUnmerged")
			}
		}
		row.Element.FillWidth().Height(28).Gap(8).Items(ui.Center).Hit(ui.ID(row.C), d.branch.ShortName).Tooltip(reason).Children(func() {
			ui.Text(row.C, d.branch.ShortName).Color(color).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			ui.Text(row.C, status).Color(color).FontSize(a.theme.Metrics.FontSizeS).Shrink(0)
		})
	}).Scrollbars().FillWidth().Height(height)
}

// drawBranchDeleteList declares the body of the delete dialog: with many set, the branches it
// deletes and what deleting local and remote branches does; then the marked references it leaves
// out, if any.
func (a *App) drawBranchDeleteList(c ui.C, many bool) {
	b := &a.branch
	lang := a.language()
	small := a.theme.Metrics.FontSizeS
	note := func(text string) { ui.Paragraph(c, text, 3).FontSize(small).Color(a.colors.Subtle) }
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		if many {
			a.drawBranchDeleteRows(c)
			if slices.ContainsFunc(b.deleting, func(r core.GitReference) bool { return r.Kind == "local" }) {
				note(i18n.Shared(lang, "desktop.branch.deleteManyLocal"))
			}
			if slices.ContainsFunc(b.deleting, func(r core.GitReference) bool { return r.Kind == "remote" }) {
				note(i18n.Shared(lang, "desktop.branch.deleteManyRemote"))
			}
		}
		if b.deleteSkipped > 0 {
			note(i18n.SharedFormat(lang, "desktop.branch.deleteSkipped", map[string]string{"count": strconv.Itoa(b.deleteSkipped)}))
		}
	})
}
