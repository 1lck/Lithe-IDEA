package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file declares the dialogs of the Git review: the annotation (blame) dialog, the listing
// of an untracked directory and the rollback confirmation, with the helpers the Diff tab shares
// for its line numbers. State and actions are in gitreview.go; the Diff tab is declared in
// difftab_view.go.

// reviewOverlays declares the review dialogs of the project that are open. They paint over
// the workbench like the other Git dialogs.
func (a *App) reviewOverlays(c ui.C, p *project) {
	r := &p.review
	if r.blame.open {
		a.drawBlameDialog(c, p)
	}
	if r.untracked.open {
		a.drawUntrackedDialog(c, p)
	}
	if r.rollback.open {
		a.drawRollbackDialog(c, p)
	}
	if r.push.open {
		a.drawPushDialog(c, p)
	}
	if r.tools.open {
		a.drawToolsDialog(c, p)
	}
	if p.lineHistory.open {
		a.drawLineHistoryDialog(c, p)
	}
	if p.rebase.open {
		a.drawRebaseDialog(c, p)
	}
	if a.pullRequests.open {
		a.drawPullRequestsDialog(c, p)
	}
}

// shortHash is the first seven characters of hash, the way Git abbreviates a commit.
func shortHash(hash string) string {
	if len(hash) > 7 {
		return hash[:7]
	}
	return hash
}

// lineNumber is a line number as the diff's gutter shows it, empty for none.
func lineNumber(n *int) string {
	if n == nil {
		return ""
	}
	return strconv.Itoa(*n)
}

// --- Blame ---

// drawBlameDialog declares the annotations of one file: for every line the short commit, its
// author and date, and the line's text.
func (a *App) drawBlameDialog(c ui.C, p *project) {
	b := &p.review.blame
	open := true
	title := i18n.SharedFormat(a.language(), "desktop.gitReview.blameTitle", map[string]string{"file": b.path})
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		switch {
		case b.loading:
			a.gitEmpty(c, i18n.Shared(a.language(), "git.loadingDiff"))
		case b.err != "":
			ui.Paragraph(c, b.err, 4).Color(a.theme.Danger)
		default:
			size := a.theme.Metrics.FontSizeS
			ui.List(c, &b.list, len(b.lines), func(row ui.ListRow) {
				line := b.lines[row.Index]
				text := ""
				if line.Line-1 < len(b.text) && line.Line >= 1 {
					text = b.text[line.Line-1]
				}
				hash, who, when := line.Hash, line.AuthorName, blameDate(line)
				if line.Uncommitted() {
					hash, who, when = "", i18n.Shared(a.language(), "git.blame.uncommitted"), ""
				} else {
					hash = shortHash(hash)
				}
				row.Element.FillWidth().Height(reviewRowHeight).Items(ui.Center).Gap(8).PadX(8).Children(func() {
					ui.Text(row.C, hash).Mono().FontSize(size).Color(a.colors.Accent).Width(64).Shrink(0)
					ui.Text(row.C, who).FontSize(size).Color(a.colors.Subtle).Ellipsis().Width(140).Shrink(0)
					ui.Text(row.C, when).FontSize(size).Color(a.colors.Subtle).Width(84).Shrink(0)
					ui.Text(row.C, strconv.Itoa(line.Line)).Mono().FontSize(size).Color(a.colors.Subtle).Width(40).Shrink(0).TextEnd()
					ui.Text(row.C, text).Mono().FontSize(size).Ellipsis().Grow(1)
				})
			}).Grow(1).FillWidth().Background(a.colors.Editor)
		}
	}, func() {
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { b.open = false; b.gen++ })
	}
}

// --- Untracked directory ---

// drawUntrackedDialog declares the listing of one level of a summarized untracked directory.
// A subdirectory opens, a file can be staged on its own.
func (a *App) drawUntrackedDialog(c ui.C, p *project) {
	u := &p.review.untracked
	if len(u.trail) == 0 {
		return
	}
	directory := u.trail[len(u.trail)-1]
	open := true
	title := i18n.SharedFormat(a.language(), "desktop.gitReview.untrackedTitle", map[string]string{"path": directory})
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 620, Height: 440}, func() {
		switch {
		case u.loading:
			a.gitEmpty(c, i18n.Shared(a.language(), "git.loadingDiff"))
		case u.err != "":
			ui.Paragraph(c, u.err, 4).Color(a.theme.Danger)
		default:
			ui.List(c, &u.list, len(u.changes), func(row ui.ListRow) {
				change := u.changes[row.Index]
				folder := len(change.Path) > 0 && change.Path[len(change.Path)-1] == '/'
				row.Element.FillWidth().Height(reviewRowHeight + 4).Items(ui.Center).Gap(8).PadX(8).Children(func() {
					ui.Text(row.C, change.Path).Ellipsis().Grow(1)
					if folder {
						ui.Text(row.C, strconv.Itoa(change.UntrackedFileCount)).Muted().Shrink(0)
						if ui.Button(row.C, a.text.Commit.StageFile(change.Path)).Ghost().Clicked() {
							c.After(func() { a.stageUntracked(p, change) })
						}
						return
					}
					if ui.Button(row.C, a.text.Commit.StageFile(change.Path)).Ghost().Clicked() {
						c.After(func() { a.stageUntracked(p, change) })
					}
				})
				if folder && row.Element.Clicked() {
					c.After(func() { a.enterUntracked(p, change.Path) })
				}
			}).Grow(1).FillWidth()
		}
	}, func() {
		if len(u.trail) > 1 && ui.Button(c, "..").Outline().Clicked() {
			c.After(func() { a.leaveUntracked(p) })
		}
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { u.open = false; u.gen++ })
	}
}

// --- Rollback ---

// drawRollbackDialog declares the confirmation of a rollback: what is rolled back, and the
// choice to delete the local copies of added files.
func (a *App) drawRollbackDialog(c ui.C, p *project) {
	r := &p.review.rollback
	open := true
	count := strconv.Itoa(len(r.changes))
	closed := ui.ModalWith(c, &open, i18n.Shared(a.language(), "git.rollback.title"), ui.ModalSpec{Width: 520,
		Description: i18n.SharedFormat(a.language(), "git.rollbackPathsConfirm", map[string]string{"count": count})}, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, i18n.Shared(a.language(), "git.rollback.warning"), 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			for _, change := range r.changes {
				ui.Text(c.Key(change.Path), change.Path).Ellipsis()
			}
			ui.Checkbox(c, &r.deleteAdded, i18n.Shared(a.language(), "git.rollback.deleteAdded")).Disabled(r.busy)
		})
	}, func() {
		if ui.Button(c, i18n.Shared(a.language(), "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(a.language(), "git.rollback.confirm")).Destructive().Disabled(r.busy).Clicked() {
			c.After(func() { a.runRollback(p) })
		}
	})
	if (closed || !open) && !r.busy {
		c.After(func() { p.review.rollback = rollbackState{} })
	}
}
