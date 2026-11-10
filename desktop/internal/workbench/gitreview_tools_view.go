package workbench

import (
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file declares the Push dialog and the repositories dialog, and the menu that opens them,
// the Commit tool window's Stash tab and the Git tool window's Worktrees tab. State and actions are in gitreview_tools.go.

// pushTagIndexes number the choices of the Push dialog's tag select.
var pushTagIndexes = []int{0, 1, 2}

// drawGitReviewMenu declares the Git tools button of the Git tool window's stripe, with the
// menu that opens the Push dialog, the Stash tab, the Worktrees tab and the repositories.
func (a *App) drawGitReviewMenu(c ui.C, p *project) {
	r := &a.reviewMenu
	button, clicked := a.gitToolButton(c, i18n.Shared(a.language(), "desktop.gitReview.menuLabel"), icons.Ellipsis, r.open, !p.git.isRepository())
	if clicked {
		r.open = !r.open
	}
	ui.Menu(c, button, &r.open, func(menu *ui.MenuItems) {
		menu.WidthRange(240, 320)
		if menu.Item(i18n.Shared(a.language(), "git.contextMenu.push")).Clicked() {
			c.After(func() { a.openPush(p) })
		}
		if menu.Item(i18n.Shared(a.language(), "git.saved.stashes")).Clicked() {
			c.After(a.showStashes)
		}
		if menu.Item(i18n.Shared(a.language(), "git.worktrees")).Clicked() {
			c.After(a.showWorktrees)
		}
		if menu.Item(i18n.Shared(a.language(), "git.repositories")).Clicked() {
			c.After(func() { a.openTools(p) })
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
	title := i18n.SharedFormat(a.language(), "git.pushDialog.title", map[string]string{"repository": p.name})
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 640, Height: 480, Description: i18n.Shared(a.language(), "git.pushDialog.description")}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			switch {
			case s.loading && !s.hasPrev:
				a.gitEmpty(c, i18n.Shared(a.language(), "git.pushDialog.loading"))
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
					ui.Text(c, i18n.Shared(a.language(), "git.pushDialog.createsRemoteBranch")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent).Shrink(0)
				}
			})
			if pv.TargetKind == "divergent" {
				upstream := ""
				if pv.Upstream != nil {
					upstream = *pv.Upstream
				}
				ui.Paragraph(c, i18n.SharedFormat(a.language(), "git.pushDialog.divergentWarning", map[string]string{"branch": pv.LocalBranch, "upstream": upstream}), 3).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				ui.Row(c).FillWidth().Shrink(0).Gap(8).Children(func() {
					publish := s.target == core.PushTargetPublish
					if ui.Checkbox(c, &publish, i18n.SharedFormat(a.language(), "git.pushDialog.publishSameName", map[string]string{"remote": pv.Remote, "branch": pv.LocalBranch})).Disabled(s.busy).Clicked() {
						c.After(func() { s.target = core.PushTargetPublish; a.loadPush(p) })
					}
					toUpstream := s.target == core.PushTargetUpstream
					if ui.Checkbox(c, &toUpstream, i18n.SharedFormat(a.language(), "git.pushDialog.pushToUpstream", map[string]string{"branch": upstream})).Disabled(s.busy).Clicked() {
						c.After(func() { s.target = core.PushTargetUpstream; a.loadPush(p) })
					}
				})
			}
			if len(pv.Commits) == 0 && !pv.CreatesRemoteBranch {
				ui.Text(c, i18n.Shared(a.language(), "git.pushDialog.noCommits")).Muted()
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
					ui.Text(c, i18n.Shared(a.language(), "git.pushDialog.moreCommits")).FontSize(size).Muted()
				}
			})
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, i18n.Shared(a.language(), "git.pushDialog.pushTags")).Shrink(0)
				names := []string{a.text.Sync.TagsNone, i18n.Shared(a.language(), "git.pushDialog.tagsReachable"), i18n.Shared(a.language(), "git.pushDialog.tagsAll")}
				before := s.tags
				ui.Select(c, &s.tags, pushTagIndexes, func(i int) string { return names[i] }).Label(i18n.Shared(a.language(), "git.pushDialog.pushTags")).Disabled(s.busy)
				if s.tags != before {
					c.After(func() { a.loadPush(p) })
				}
				ui.Spacer(c)
				ui.Checkbox(c, &s.force, i18n.Shared(a.language(), "git.pushDialog.forcePush")).Disabled(s.busy)
			})
			if s.force {
				ui.Paragraph(c, i18n.Shared(a.language(), "git.pushDialog.forcePushHint"), 3).FontSize(size).Color(a.colors.Warning)
			}
			if s.busy {
				ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
					ui.Text(c, i18n.Shared(a.language(), "git.pushing")).Shrink(0)
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
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		label := i18n.Shared(a.language(), "git.push")
		if s.force {
			label = i18n.Shared(a.language(), "git.pushDialog.forcePush")
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

// drawToolsDialog declares the dialog of the repositories Core discovered under the project
// folder.
func (a *App) drawToolsDialog(c ui.C, p *project) {
	t := &p.review.tools
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(a.language(), "git.repositories"), ui.ModalSpec{Width: 720, Height: 520}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			if t.err != "" {
				ui.Paragraph(c, t.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			a.drawRepositories(c, p)
		})
	}, func() {
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.refresh")).Outline().Disabled(t.loading).Clicked() {
			c.After(func() { a.loadTools(p) })
		}
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { a.closeTools(p) })
	}
}

// drawRepositories declares the repositories Core discovered under the project folder, the
// first being the one the Commit window acts on.
func (a *App) drawRepositories(c ui.C, p *project) {
	t := &p.review.tools
	if len(t.repositories) == 0 {
		a.gitEmpty(c, i18n.Shared(a.language(), "git.noRepositoriesFound"))
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
