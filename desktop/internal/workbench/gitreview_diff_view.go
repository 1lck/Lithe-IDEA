package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the dialogs of the Diff review: the Diff dialog with its block toggles,
// the annotation (blame) dialog, the listing of an untracked directory and the rollback
// confirmation. State and actions are in gitreview.go.

const (
	// reviewNumberWidth is the width of a line-number column of the diff.
	reviewNumberWidth = 44
	reviewBlockHeight = 28
)

// reviewOverlays declares the review dialogs of the project that are open. They paint over
// the workbench like the other Git dialogs.
func (a *App) reviewOverlays(c ui.C, p *project) {
	r := &p.review
	if r.diff.open {
		a.drawDiffDialog(c, p)
	}
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
}

// lineNumber is a line number as the diff's gutter shows it, empty for none.
func lineNumber(n *int) string {
	if n == nil {
		return ""
	}
	return strconv.Itoa(*n)
}

// diffLineColor is the color of a unified line by its type.
func (a *App) diffLineColor(lineType string) gfx.Color {
	switch lineType {
	case "added":
		return a.colors.Success
	case "removed":
		return a.colors.Deleted
	case "header":
		return a.colors.Accent
	}
	return a.colors.Text
}

// diffRowColors are the colors of the left and right text of an aligned row.
func (a *App) diffRowColors(kind string) (left, right gfx.Color) {
	switch kind {
	case "addition":
		return a.colors.Text, a.colors.Success
	case "removal":
		return a.colors.Deleted, a.colors.Text
	case "changed":
		return a.colors.Deleted, a.colors.Success
	case "information":
		return a.colors.Accent, a.colors.Accent
	}
	return a.colors.Text, a.colors.Text
}

// drawDiffDialog declares the Diff dialog: the unified or side-by-side view of one file, with
// a header over each block that stages or unstages it and, for an unstaged one, rolls it back.
func (a *App) drawDiffDialog(c ui.C, p *project) {
	d := &p.review.diff
	title := a.reviewText("git.diff.title") + " — " + d.change.Path
	switch {
	case d.staged:
		title += " (" + a.reviewText("git.diff.stagedChanges") + ")"
	case d.plan != nil:
		title += " (" + a.reviewText("git.diff.unstagedChanges") + ")"
	}
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		ui.Column(c).Fill().Gap(6).Children(func() {
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				mode := []bool{false, true}
				ui.Tabs(c, &d.split, mode, func(split bool) string {
					if split {
						return a.reviewText("git.diff.split")
					}
					return a.reviewText("git.diff.unified")
				}).Label(a.reviewText("desktop.gitReview.diffTab"))
				ui.Spacer(c)
				if d.note != "" {
					ui.Text(c, d.note).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Shrink(1)
				}
			})
			if d.split != d.splitShown() {
				c.After(func() { d.rebuild() })
			}
			switch {
			case d.loading && d.file == nil:
				a.gitEmpty(c, a.reviewText("git.loadingDiff"))
			case d.err != "":
				ui.Paragraph(c, d.err, 4).Color(a.theme.Danger)
			case d.file == nil || d.file.IsBinary:
				name := d.change.Path
				text := a.reviewText("git.diff.noDifferences")
				if d.file != nil {
					text = a.reviewFormat("git.binaryDiffDescription", map[string]string{"name": name})
				}
				a.gitEmpty(c, text)
			default:
				ui.List(c, &d.list, len(d.items), func(row ui.ListRow) { a.drawDiffItem(c, p, row) }).Grow(1).FillWidth().Background(a.colors.Editor)
			}
		})
	}, func() {
		if ui.Button(c, a.reviewText("desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { a.closeDiff(p) })
	}
}

// splitShown is the mode the rows were built for: they stand for the split view when any row
// of the aligned kind has been laid out.
func (d *diffState) splitShown() bool {
	if len(d.items) == 0 {
		return d.split
	}
	return d.items[0].row >= 0
}

// drawDiffItem declares one row of the diff list.
func (a *App) drawDiffItem(c ui.C, p *project, row ui.ListRow) {
	d := &p.review.diff
	if row.Index >= len(d.items) {
		return
	}
	item := d.items[row.Index]
	box := row.Element.FillWidth().Height(reviewRowHeight).Items(ui.Center).Gap(6).PadX(8)
	if item.block != nil {
		box.Height(reviewBlockHeight).Background(a.colors.Hover).Children(func() { a.drawDiffBlock(row.C, p, item) })
		return
	}
	size := a.theme.Metrics.FontSizeS
	if item.row >= 0 && item.row < len(d.file.Rows) {
		r := d.file.Rows[item.row]
		left, right := a.diffRowColors(r.Kind)
		box.Children(func() {
			ui.Text(row.C, lineNumber(r.OldLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
			ui.Text(row.C, r.Left).Mono().FontSize(size).Color(left).Ellipsis().Grow(1).Basis(0)
			ui.Text(row.C, lineNumber(r.NewLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
			ui.Text(row.C, r.Text()).Mono().FontSize(size).Color(right).Ellipsis().Grow(1).Basis(0)
		})
		return
	}
	if item.line >= 0 && item.line < len(d.file.Lines) {
		l := d.file.Lines[item.line]
		box.Children(func() {
			ui.Text(row.C, lineNumber(l.OldLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
			ui.Text(row.C, lineNumber(l.NewLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
			ui.Text(row.C, l.Content).Mono().FontSize(size).Color(a.diffLineColor(l.LineType)).Ellipsis().Grow(1)
		})
	}
}

// drawDiffBlock declares the header over one block: a checkbox that stages or unstages it
// and, for a block Core allows to roll back, the rollback with its confirmation.
func (a *App) drawDiffBlock(c ui.C, p *project, item diffItem) {
	d, block := &p.review.diff, item.block
	number := a.reviewFormat("desktop.gitReview.blockN", map[string]string{"n": strconv.Itoa(item.number)})
	label := a.reviewText("git.diff.includeBlock")
	if block.Checked {
		label = a.reviewText("git.diff.excludeBlock")
	}
	checked := block.Checked
	if ui.Checkbox(c, &checked, label).Label(label).Disabled(d.busy || !block.CanToggle).Clicked() {
		b := *block
		c.After(func() { a.toggleDiffBlock(p, b) })
	}
	ui.Text(c, number).Weight(gfx.WeightMedium).Shrink(0)
	ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Grow(1)
	if !block.CanRollback {
		return
	}
	if d.confirm == block.ID {
		ui.Text(c, a.reviewFormat("git.diff.rollbackHunkConfirm", map[string]string{"path": d.change.Path})).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Shrink(1)
		if ui.Button(c, a.reviewText("git.rollback.confirm")).Destructive().Disabled(d.busy).Clicked() {
			id := block.ID
			c.After(func() { a.writeDiffBlock(p, id, core.DiffBlockRollback) })
		}
		if ui.Button(c, a.reviewText("desktop.gitReview.cancel")).Outline().Clicked() {
			c.After(func() { d.confirm = "" })
		}
		return
	}
	if ui.Button(c, a.reviewText("git.diff.rollbackHunk")).Ghost().Disabled(d.busy).Clicked() {
		id := block.ID
		c.After(func() { d.confirm = id })
	}
}

// --- Blame ---

// drawBlameDialog declares the annotations of one file: for every line the short commit, its
// author and date, and the line's text.
func (a *App) drawBlameDialog(c ui.C, p *project) {
	b := &p.review.blame
	open := true
	title := a.reviewFormat("desktop.gitReview.blameTitle", map[string]string{"file": b.path})
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		switch {
		case b.loading:
			a.gitEmpty(c, a.reviewText("git.loadingDiff"))
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
					hash, who, when = "", a.reviewText("git.blame.uncommitted"), ""
				} else if len(hash) > 7 {
					hash = hash[:7]
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
		if ui.Button(c, a.reviewText("desktop.gitReview.close")).Outline().Clicked() {
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
	title := a.reviewFormat("desktop.gitReview.untrackedTitle", map[string]string{"path": directory})
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 620, Height: 440}, func() {
		switch {
		case u.loading:
			a.gitEmpty(c, a.reviewText("git.loadingDiff"))
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
		if ui.Button(c, a.reviewText("desktop.gitReview.close")).Outline().Clicked() {
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
	closed := ui.ModalWith(c, &open, a.reviewText("git.rollback.title"), ui.ModalSpec{Width: 520,
		Description: a.reviewFormat("git.rollbackPathsConfirm", map[string]string{"count": count})}, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, a.reviewText("git.rollback.warning"), 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			for _, change := range r.changes {
				ui.Text(c.Key(change.Path), change.Path).Ellipsis()
			}
			ui.Checkbox(c, &r.deleteAdded, a.reviewText("git.rollback.deleteAdded")).Disabled(r.busy)
		})
	}, func() {
		if ui.Button(c, a.reviewText("desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, a.reviewText("git.rollback.confirm")).Destructive().Disabled(r.busy).Clicked() {
			c.After(func() { a.runRollback(p) })
		}
	})
	if (closed || !open) && !r.busy {
		c.After(func() { p.review.rollback = rollbackState{} })
	}
}
