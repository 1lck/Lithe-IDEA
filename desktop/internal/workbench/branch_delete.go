package workbench

import (
	"context"
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
	// target is the commit a deleted local branch pointed at; empty for a remote branch.
	target string
	err    error
}

// confirmDelete deletes the branches the delete dialog lists, one after another. A single branch
// that fails keeps the dialog open with Git's reason, as the other branch writes do. Several are
// all attempted; the dialog closes and one notice says how many were deleted, or how many failed
// and why the first did.
func (a *App) confirmDelete(p *project) {
	b := &a.branch
	if b.busy || len(b.deleting) == 0 {
		return
	}
	branches := slices.Clone(b.deleting)
	root := a.branchRoot(p)
	remote := slices.ContainsFunc(branches, func(r core.GitReference) bool { return r.Kind == "remote" })
	timeout := branchOperationTimeout
	if remote {
		// Deleting a remote branch pushes, which waits on the network as a push does.
		timeout = syncTimeout
	}
	action := "git.branch.delete"
	switch {
	case len(branches) > 1:
		action = "git.branch.deleteMany"
	case remote:
		action = "git.branch.deleteRemote"
	}
	a.performed(action, surfaceButton)
	results := make([]branchDeletion, len(branches))
	a.runBranchWriteWithin(p, timeout, "git_branch_delete", a.text.Branch.DeleteFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			for i, r := range branches {
				results[i] = deleteOneBranch(ctx, kernel, root, r)
			}
			if len(results) == 1 {
				return results[0].err
			}
			return nil
		},
		func(a *App, status core.GitStatus) { a.reportDeletions(p, root, results) })
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

// reportDeletions forgets the deleted branches in the log of root and says how deleting ended.
// A single branch reached here only when it was deleted. Once a branch is deleted, the marks of
// the branches pane go, so that what stays marked is not deleted by the next press of Delete.
func (a *App) reportDeletions(p *project, root string, results []branchDeletion) {
	lang := a.language()
	var failed []branchDeletion
	for _, d := range results {
		if d.err != nil {
			failed = append(failed, d)
			a.operationFailed("git_branch_delete", d.err)
			continue
		}
		a.dropLogReference(p, root, d.branch.FullName)
	}
	if len(failed) < len(results) && root == p.logRepositoryRoot() {
		a.logView.forgetLogRefMarks()
	}
	switch {
	case len(failed) > 0:
		first := failed[0]
		a.notifyError(i18n.SharedFormat(lang, "desktop.branch.deleteManyFailed", map[string]string{
			"failed": strconv.Itoa(len(failed)), "total": strconv.Itoa(len(results)),
			"name": first.branch.ShortName, "reason": first.err.Error()}))
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
	var body func()
	if many || b.deleteSkipped > 0 {
		body = func() { a.drawBranchDeleteList(c, many) }
	}
	a.branchDialogOf(c, title, prompt, body, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, t.DeleteButton).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() { a.confirmDelete(p) })
		}
	})
}

// drawBranchDeleteList declares the body of the delete dialog: with many set, the branches it
// deletes and what deleting local and remote branches does; then the marked references it leaves
// out, if any.
func (a *App) drawBranchDeleteList(c ui.C, many bool) {
	b, g := &a.branch, a.text.Git
	lang := a.language()
	small := a.theme.Metrics.FontSizeS
	note := func(text string) { ui.Paragraph(c, text, 3).FontSize(small).Color(a.colors.Subtle) }
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		if many {
			ui.Scroll(c).Scrollbars().FillWidth().MaxHeight(branchBlockingHeight).Children(func() {
				ui.Column(c).FillWidth().Gap(2).Children(func() {
					for _, r := range b.deleting {
						kind := g.LocalGroup
						if r.Kind == "remote" {
							kind = g.RemoteGroup
						}
						ui.Row(c.Key(r.FullName)).FillWidth().Gap(8).Children(func() {
							ui.Text(c, r.ShortName).Grow(1).Shrink(1).MinWidth(0).FontSize(small).Color(a.colors.Text).Ellipsis()
							ui.Text(c, kind).Shrink(0).FontSize(small).Color(a.colors.Subtle)
						})
					}
				})
			})
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
