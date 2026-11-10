package workbench

import (
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file declares the Push dialog and the dialog of the stash, worktree and repository
// tools, and the menu that opens them. State and actions are in gitreview_tools.go.

// pushTagIndexes number the choices of the Push dialog's tag select.
var pushTagIndexes = []int{0, 1, 2}

// drawGitReviewMenu declares the Git tools button of the Git tool window's stripe, with the
// menu that opens the Push dialog and the stash, worktree and repository tools.
func (a *App) drawGitReviewMenu(c ui.C, p *project) {
	r := &a.reviewMenu
	button, clicked := a.gitToolButton(c, a.reviewText("desktop.gitReview.menuLabel"), icons.Ellipsis, r.open, !p.git.isRepository())
	if clicked {
		r.open = !r.open
	}
	ui.Menu(c, button, &r.open, func(menu *ui.MenuItems) {
		menu.WidthRange(240, 320)
		if menu.Item(a.reviewText("git.contextMenu.push")).Clicked() {
			c.After(func() { a.openPush(p) })
		}
		if menu.Item(a.reviewText("git.saved.stashes")).Clicked() {
			c.After(func() { a.openTools(p, toolsStashes) })
		}
		if menu.Item(a.reviewText("git.worktrees")).Clicked() {
			c.After(func() { a.openTools(p, toolsWorktrees) })
		}
		if menu.Item(a.reviewText("git.repositories")).Clicked() {
			c.After(func() { a.openTools(p, toolsRepositories) })
		}
	})
}

// reviewMenuState is the window's state of the Git tools menu.
type reviewMenuState struct{ open bool }

// drawPushDialog declares the Push dialog: the destination and the commits Core found, the
// tag policy, the choice a divergent destination needs and the force option, with Git's
// progress while the push runs.
func (a *App) drawPushDialog(c ui.C, p *project) {
	s := &p.review.push
	title := a.reviewFormat("git.pushDialog.title", map[string]string{"repository": p.name})
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 640, Height: 480, Description: a.reviewText("git.pushDialog.description")}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			switch {
			case s.loading && !s.hasPrev:
				a.gitEmpty(c, a.reviewText("git.pushDialog.loading"))
				return
			case s.err != "":
				ui.Paragraph(c, s.err, 4).Color(a.theme.Danger)
				return
			}
			pv := s.preview
			destination := pv.Remote + "/" + pv.RemoteBranch
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, pv.LocalBranch).Weight(600).Shrink(0)
				ui.Text(c, "→").Muted().Shrink(0)
				ui.Text(c, destination).Ellipsis().Shrink(1)
				if pv.CreatesRemoteBranch {
					ui.Text(c, a.reviewText("git.pushDialog.createsRemoteBranch")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent).Shrink(0)
				}
			})
			if pv.TargetKind == "divergent" {
				upstream := ""
				if pv.Upstream != nil {
					upstream = *pv.Upstream
				}
				ui.Paragraph(c, a.reviewFormat("git.pushDialog.divergentWarning", map[string]string{"branch": pv.LocalBranch, "upstream": upstream}), 3).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				ui.Row(c).FillWidth().Shrink(0).Gap(8).Children(func() {
					publish := s.target == core.PushTargetPublish
					if ui.Checkbox(c, &publish, a.reviewFormat("git.pushDialog.publishSameName", map[string]string{"remote": pv.Remote, "branch": pv.LocalBranch})).Disabled(s.busy).Clicked() {
						c.After(func() { s.target = core.PushTargetPublish; a.loadPush(p) })
					}
					toUpstream := s.target == core.PushTargetUpstream
					if ui.Checkbox(c, &toUpstream, a.reviewFormat("git.pushDialog.pushToUpstream", map[string]string{"branch": upstream})).Disabled(s.busy).Clicked() {
						c.After(func() { s.target = core.PushTargetUpstream; a.loadPush(p) })
					}
				})
			}
			if len(pv.Commits) == 0 && !pv.CreatesRemoteBranch {
				ui.Text(c, a.reviewText("git.pushDialog.noCommits")).Muted()
			}
			size := a.theme.Metrics.FontSizeS
			ui.Scroll(c).Grow(1).FillWidth().Children(func() {
				for _, commit := range pv.Commits {
					ui.Row(c.Key(commit.Hash)).FillWidth().Height(reviewRowHeight + 2).Items(ui.Center).Gap(8).PadX(4).Children(func() {
						ui.Text(c, commit.ShortHash).Mono().FontSize(size).Color(a.colors.Accent).Shrink(0)
						ui.Text(c, commit.Subject).Ellipsis().Grow(1)
						ui.Text(c, commit.AuthorName).FontSize(size).Color(a.colors.Subtle).Ellipsis().Shrink(0).MaxWidth(160)
					})
				}
				if pv.HasMore {
					ui.Text(c, a.reviewText("git.pushDialog.moreCommits")).FontSize(size).Muted()
				}
			})
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, a.reviewText("git.pushDialog.pushTags")).Shrink(0)
				names := []string{a.text.Sync.TagsNone, a.reviewText("git.pushDialog.tagsReachable"), a.reviewText("git.pushDialog.tagsAll")}
				before := s.tags
				ui.Select(c, &s.tags, pushTagIndexes, func(i int) string { return names[i] }).Label(a.reviewText("git.pushDialog.pushTags")).Disabled(s.busy)
				if s.tags != before {
					c.After(func() { a.loadPush(p) })
				}
				ui.Spacer(c)
				ui.Checkbox(c, &s.force, a.reviewText("git.pushDialog.forcePush")).Disabled(s.busy)
			})
			if s.force {
				ui.Paragraph(c, a.reviewText("git.pushDialog.forcePushHint"), 3).FontSize(size).Color(a.colors.Warning)
			}
			if s.busy {
				ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
					ui.Text(c, a.reviewText("git.pushing")).Shrink(0)
					if words := a.syncProgressWords(&p.log.sync); words != "" {
						ui.Text(c, words).FontSize(size).Color(a.colors.Subtle).Ellipsis().Shrink(1)
					}
					if sync := &p.log.sync; sync.hasProgress && sync.progress.Percent != nil {
						ui.Progress(c, float32(*sync.progress.Percent)/100).Width(syncProgressWidth)
					}
				})
			}
		})
	}, func() {
		if s.busy {
			if ui.Button(c, a.text.Sync.Cancel).Outline().Clicked() {
				c.After(func() { a.cancelSync(p) })
			}
			return
		}
		if ui.Button(c, a.reviewText("desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		label := a.reviewText("git.push")
		if s.force {
			label = a.reviewText("git.pushDialog.forcePush")
		}
		btn := ui.Button(c, label).Disabled(!s.canPush())
		if s.force {
			btn = btn.Destructive()
		}
		if btn.Clicked() {
			c.After(func() { a.submitPush(p) })
		}
	})
	if (closed || !open) && !s.busy {
		c.After(func() { a.closePush(p) })
	}
}

// toolsTabs lists the tabs of the tools dialog.
var toolsTabs = []toolsTab{toolsStashes, toolsWorktrees, toolsRepositories}

// drawToolsDialog declares the stash, worktree and repository tools in one tabbed dialog.
func (a *App) drawToolsDialog(c ui.C, p *project) {
	t := &p.review.tools
	open := true
	closed := ui.ModalWith(c, &open, a.reviewText("desktop.gitReview.manageTitle"), ui.ModalSpec{Width: 720, Height: 520}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			ui.Tabs(c, &t.tab, toolsTabs, func(tab toolsTab) string {
				switch tab {
				case toolsWorktrees:
					return a.reviewText("git.worktrees")
				case toolsRepositories:
					return a.reviewText("git.repositories")
				}
				return a.reviewText("git.saved.stashes")
			})
			for _, problem := range []string{t.err, t.writeErr} {
				if problem != "" {
					ui.Paragraph(c, problem, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			}
			switch t.tab {
			case toolsWorktrees:
				a.drawWorktreesTab(c, p)
			case toolsRepositories:
				a.drawRepositoriesTab(c, p)
			default:
				a.drawStashesTab(c, p)
			}
		})
	}, func() {
		if ui.Button(c, a.reviewText("desktop.gitReview.refresh")).Outline().Disabled(t.busy || t.loading).Clicked() {
			c.After(func() { a.loadTools(p) })
		}
		if ui.Button(c, a.reviewText("desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { a.closeTools(p) })
	}
}

// drawStashesTab declares the stash list with its actions and the form that stashes the local
// changes.
func (a *App) drawStashesTab(c ui.C, p *project) {
	t := &p.review.tools
	size := a.theme.Metrics.FontSizeS
	ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
		submitted := ui.TextField(c, &t.stashMessage, a.reviewText("git.stashMessage"), a.reviewText("git.stashMessage")).Grow(1).Submitted()
		ui.Checkbox(c, &t.untracked, a.reviewText("git.saved.untracked")).Disabled(t.busy)
		stash := ui.Button(c, a.reviewText("desktop.gitReview.stashPush")).Disabled(t.busy).Clicked() || submitted
		if stash && !t.busy {
			c.After(func() { a.stashChanges(p) })
		}
	})
	if len(t.stashes) == 0 {
		a.gitEmpty(c, a.reviewText("git.noStashes"))
		return
	}
	ui.List(c, &t.stashList, len(t.stashes), func(row ui.ListRow) {
		stash := t.stashes[row.Index]
		row.Element.FillWidth().Height(reviewRowHeight + 8).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Column(row.C).Grow(1).Shrink(1).Children(func() {
				ui.Text(row.C, stash.Message).Ellipsis()
				ui.Text(row.C, stash.Date).FontSize(size).Color(a.colors.Subtle).Ellipsis()
			})
			if t.dropping == stash.OID {
				if ui.Button(row.C, a.reviewText("git.dropStash")).Destructive().Disabled(t.busy).Clicked() {
					c.After(func() { a.stashAction(p, stash, "drop") })
				}
				if ui.Button(row.C, a.reviewText("desktop.gitReview.cancel")).Outline().Clicked() {
					c.After(func() { t.dropping = "" })
				}
				return
			}
			if ui.Button(row.C, a.reviewText("git.applyStash")).Ghost().Disabled(t.busy).Clicked() {
				c.After(func() { a.stashAction(p, stash, "apply") })
			}
			if ui.Button(row.C, a.reviewText("git.popStash")).Ghost().Disabled(t.busy).Clicked() {
				c.After(func() { a.stashAction(p, stash, "pop") })
			}
			if ui.Button(row.C, a.reviewText("git.dropStash")).Ghost().Disabled(t.busy).Clicked() {
				c.After(func() { t.dropping = stash.OID })
			}
		})
	}).Grow(1).FillWidth()
}

// worktreeBranch is the branch a worktree has checked out, without the refs/heads/ prefix.
func (a *App) worktreeBranch(tree core.GitWorktree) string {
	switch {
	case tree.IsBare:
		return a.reviewText("git.worktreeDialog.bare")
	case tree.Branch == nil:
		return a.reviewText("desktop.gitReview.detached")
	}
	name := *tree.Branch
	const prefix = "refs/heads/"
	if len(name) > len(prefix) && name[:len(prefix)] == prefix {
		name = name[len(prefix):]
	}
	return name
}

// drawWorktreesTab declares the registered worktrees with lock, unlock and remove, and the
// form that adds one on a new branch started at HEAD.
func (a *App) drawWorktreesTab(c ui.C, p *project) {
	t := &p.review.tools
	size := a.theme.Metrics.FontSizeS
	ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
		ui.TextField(c, &t.branchName, a.reviewText("git.worktreeDialog.branchName"), a.reviewText("git.worktreeDialog.branchName")).Width(200).Shrink(0)
		ui.TextField(c, &t.destination, a.reviewText("git.worktreeDialog.destination"), a.reviewText("git.worktreeDialog.destination")).Grow(1)
		ready := !t.busy && t.branchName.Text() != "" && t.destination.Text() != ""
		if ui.Button(c, a.reviewText("git.newWorktree")).Disabled(!ready).Clicked() {
			c.After(func() { a.createWorktree(p) })
		}
	})
	if hasPrunable(t.worktrees) {
		if ui.Button(c, a.reviewText("desktop.gitReview.prune")).Outline().Disabled(t.busy).Clicked() {
			c.After(func() { a.worktreeAction(p, core.GitWorktree{}, "prune") })
		}
	}
	if len(t.worktrees) == 0 {
		a.gitEmpty(c, a.reviewText("git.noWorktreesFound"))
		return
	}
	ui.List(c, &t.treeList, len(t.worktrees), func(row ui.ListRow) {
		tree := t.worktrees[row.Index]
		row.Element.FillWidth().Height(reviewRowHeight + 14).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Column(row.C).Grow(1).Shrink(1).Children(func() {
				name := a.worktreeBranch(tree)
				if tree.IsPrimary {
					name += " · " + a.reviewText("git.worktreeDialog.primary")
				}
				if tree.IsLocked {
					name += " · " + a.reviewText("git.worktreeDialog.locked")
				}
				if tree.IsPrunable {
					name += " · " + a.reviewText("git.worktreeDialog.missing")
				}
				ui.Text(row.C, name).Ellipsis()
				ui.Text(row.C, filepath.FromSlash(tree.Path)).FontSize(size).Color(a.colors.Subtle).Ellipsis()
			})
			if tree.IsPrimary || tree.IsCurrent {
				return
			}
			if t.removing == tree.Path {
				if ui.Button(row.C, a.reviewText("git.worktreeDialog.remove")).Destructive().Disabled(t.busy).Clicked() {
					c.After(func() { a.worktreeAction(p, tree, "remove") })
				}
				if ui.Button(row.C, a.reviewText("desktop.gitReview.cancel")).Outline().Clicked() {
					c.After(func() { t.removing = "" })
				}
				return
			}
			lock, action := a.reviewText("desktop.gitReview.lock"), "lock"
			if tree.IsLocked {
				lock, action = a.reviewText("desktop.gitReview.unlock"), "unlock"
			}
			if ui.Button(row.C, lock).Ghost().Disabled(t.busy).Clicked() {
				c.After(func() { a.worktreeAction(p, tree, action) })
			}
			if ui.Button(row.C, a.reviewText("git.worktreeDialog.remove")).Ghost().Disabled(t.busy || tree.IsLocked).Clicked() {
				c.After(func() { t.removing = tree.Path })
			}
		})
		if t.removing == tree.Path {
			ui.Paragraph(row.C, a.reviewFormat("git.worktreeDialog.removeConfirm", map[string]string{"path": tree.Path}), 2).FontSize(size).Color(a.colors.Warning)
		}
	}).Grow(1).FillWidth()
}

// drawRepositoriesTab declares the repositories Core discovered under the project folder, the
// first being the one the Commit window acts on.
func (a *App) drawRepositoriesTab(c ui.C, p *project) {
	t := &p.review.tools
	if len(t.repositories) == 0 {
		a.gitEmpty(c, a.reviewText("git.noRepositoriesFound"))
		return
	}
	ui.List(c, &t.repoList, len(t.repositories), func(row ui.ListRow) {
		repo := t.repositories[row.Index]
		row.Element.FillWidth().Height(reviewRowHeight + 6).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Icon(row.C, icons.GitBranch).Size(14, 14).Color(a.colors.Subtle)
			ui.Text(row.C, filepath.Base(filepath.FromSlash(repo.Path))).Shrink(0)
			ui.Text(row.C, strconv.Itoa(row.Index+1)).Muted().Shrink(0)
			ui.Text(row.C, filepath.FromSlash(repo.Path)).Muted().Ellipsis().Grow(1)
		})
	}).Grow(1).FillWidth()
}
