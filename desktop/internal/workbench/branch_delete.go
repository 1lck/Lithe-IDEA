package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
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
	if a.branch.busy || len(branches) == 0 {
		return
	}
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target = branchDialogDelete, branches[0]
	b.deleting, b.deleteSkipped = slices.Clone(branches), skipped
	b.deleteReport = &branchDeleteReport{root: a.branchRoot(a.project), fromPopup: b.fromPopup}
	b.deleteFromNotice, b.deleteError = false, ""
	b.deleteList, b.deleteResultList = ui.ListState{}, ui.ListState{}
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

// branchDeleteReport keeps a batch and its reviewed tips tied to the original repository.
type branchDeleteReport struct {
	root      string
	fromPopup bool
	results   []branchDeletion
	unmerged  []branchDeletion
}

// inView reports whether the user is still on the surface that started the deletion.
// The Log's repository selection can change independently of the branch popup's repo.
func (r *branchDeleteReport) inView(a *App, p *project) bool {
	if !a.chrome.isOpen(catalogIndex[itemGit]) {
		return false
	}
	if r.fromPopup {
		return a.layout.gitTab == gitTabConsole && r.root == a.branchRoot(p)
	}
	return a.layout.gitTab == gitTabLog && r.root == p.logRepositoryRoot()
}

func (r *branchDeleteReport) repositoryLabel(lang i18n.Language) string {
	return i18n.SharedFormat(lang, "desktop.branch.deleteRepository", map[string]string{"repository": filepath.Base(r.root)})
}

// confirmDelete closes the confirmation and deletes its branches in order. Batches retain
// each outcome, and unmerged local branches can be reviewed for a second confirmation.
func (a *App) confirmDelete(p *project) {
	b := &a.branch
	force := b.dialog == branchDialogForceDelete
	report := b.deleteReport
	if b.busy || report == nil || len(b.deleting) == 0 || b.dialog != branchDialogDelete && !force {
		return
	}
	if force && len(report.unmerged) != len(b.deleting) {
		return
	}
	if !b.deleteFromNotice && (report.root != a.branchRoot(p) || !report.fromPopup && report.root != p.logRepositoryRoot()) {
		a.operationRejected("git_branch_delete", "repository_changed")
		a.notifyError(i18n.Shared(a.language(), "desktop.branch.deleteRepositoryChanged"))
		a.cancelBranchDialog()
		return
	}
	branches := slices.Clone(b.deleting)
	reviews := slices.Clone(report.unmerged)
	root := report.root
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
	b.dialog, b.busy = branchDialogNone, true
	if report.fromPopup && !b.deleteFromNotice {
		a.showGitConsole("")
	}
	kernel := a.kernel
	updatesProject := root == p.git.repositoryRoot(p.root)
	results := make([]branchDeletion, len(branches))
	a.background(p, timeout, func(ctx context.Context) func(*App) {
		if remote {
			// The push that deletes a remote branch may ask for credentials.
			ctx = a.gitAuthentication(ctx)
		}
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
		if changed && updatesProject {
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
			if b.deleteReport != report {
				return
			}
			b.busy = false
			if changed && updatesProject && refreshErr == nil && root == p.git.repositoryRoot(p.root) {
				if a.setGit(p, gitState{loaded: true, status: status}, generation) {
					a.gitStatusPublished(p)
				}
			}
			a.reportDeletions(p, report, results)
			if refreshErr != nil {
				a.notifyError(a.text.Branch.DeleteFailed(refreshErr.Error()))
			}
			if changed && p.log.started {
				if root == p.logRepositoryRoot() || slices.ContainsFunc(p.log.walks, func(w logWalk) bool { return w.root == root }) {
					a.loadLog(p)
				} else {
					a.loadNestedReferences(p)
				}
			}
			if changed && b.open && root == a.branchRoot(p) {
				a.loadBranches(p)
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
func (a *App) reportDeletions(p *project, report *branchDeleteReport, results []branchDeletion) {
	for _, d := range results {
		i := slices.IndexFunc(report.results, func(previous branchDeletion) bool { return previous.branch.FullName == d.branch.FullName })
		if i < 0 {
			report.results = append(report.results, d)
		} else {
			report.results[i] = d
		}
		if d.err == nil {
			a.dropLogReference(p, report.root, d.branch.FullName)
		}
	}
	if slices.ContainsFunc(results, func(d branchDeletion) bool { return d.err == nil }) && report.root == p.logRepositoryRoot() {
		a.logView.forgetLogRefMarks()
	}

	report.unmerged = report.unmerged[:0]
	var failed []branchDeletion
	for _, d := range report.results {
		if d.err == nil {
			continue
		}
		failed = append(failed, d)
		if review, ok := core.BranchDeleteReview(d.err); ok {
			d.target = review.ExpectedTarget
			report.unmerged = append(report.unmerged, d)
		}
	}
	canPresent := a.canPresentGitResult(p) && !a.branch.open && report.inView(a, p)
	lang := a.language()
	switch {
	case len(report.unmerged) > 0:
		if canPresent {
			a.showBranchDeleteReport(report, a.branch.deleteFromNotice)
			return
		}
		a.notifyBranchDeleteReport(p, report, i18n.Shared(lang, "desktop.branch.unmergedTitle"))
	case len(failed) == 1 && len(report.results) == 1:
		reason := a.branchDeletionReason(failed[0].err)
		if canPresent {
			a.branch.dialog, a.branch.target, a.branch.deleteError = branchDialogDelete, failed[0].branch, reason
		}
		a.notifyError(a.text.Branch.DeleteFailed(reason))
	case len(failed) > 0:
		if canPresent {
			a.showBranchDeleteReport(report, a.branch.deleteFromNotice)
		}
		first := failed[0]
		message := i18n.SharedFormat(lang, "desktop.branch.deleteManyFailed", map[string]string{
			"failed": strconv.Itoa(len(failed)), "total": strconv.Itoa(len(report.results)),
			"name": first.branch.ShortName, "reason": a.branchDeletionReason(first.err)})
		a.notifyBranchDeleteReport(p, report, message)
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

func (a *App) notifyBranchDeleteReport(p *project, report *branchDeleteReport, title string) {
	lang, owner := a.language(), p.ctx
	a.notifyOperationAction(title, report.root,
		i18n.Shared(lang, "desktop.branch.openDeleteResult"), func(a *App) {
			p := a.project
			if p != nil && p.ctx == owner && a.canPresentGitResult(p) && !a.branch.busy {
				a.performed("git.branch.openDeleteResult", surfaceNotification)
				a.closeBranches()
				a.showBranchDeleteReport(report, true)
			}
		})
}

func (a *App) showBranchDeleteReport(report *branchDeleteReport, fromNotice bool) {
	b := &a.branch
	b.deleteReport, b.deleteFromNotice = report, fromNotice
	b.deleteError = ""
	b.deleteList, b.deleteResultList = ui.ListState{}, ui.ListState{}
	b.dialog = branchDialogDeleteResult
	if len(report.unmerged) > 0 {
		b.dialog = branchDialogDeleteUnmerged
		b.deleting, b.deleteSkipped = nil, 0
		for _, item := range report.unmerged {
			b.deleting = append(b.deleting, item.branch)
		}
		b.target = b.deleting[0]
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
		ui.Text(c, b.deleteReport.repositoryLabel(lang)).Weight(gfx.WeightMedium).Ellipsis()
		a.drawGitRemovalPath(c, b.deleteReport.root)
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
	results := b.deleteReport.results
	deleted := 0
	for _, d := range results {
		if d.err == nil {
			deleted++
		}
	}
	ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.branch.deleteResultSummary", map[string]string{
		"deleted": strconv.Itoa(deleted), "kept": strconv.Itoa(len(results) - deleted)}), 3)
	height := min(branchBlockingHeight, float32(len(results))*28)
	ui.List(c, &b.deleteResultList, len(results), func(row ui.ListRow) {
		d := results[row.Index]
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
