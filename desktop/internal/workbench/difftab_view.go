package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the body of a Diff tab: the toolbar that steps through the differences
// and the files and switches the modes, the names of the two sides, and the list of the rows,
// side by side or unified, with the marks of the differences beside it. State and actions are
// in difftab.go.

const (
	// reviewNumberWidth is the width of a line-number column of the diff.
	reviewNumberWidth = 44
	// reviewBlockHeight is the height of the header over a block.
	reviewBlockHeight = 28
	// diffFoldHeight is the height of a fold row.
	diffFoldHeight = 24
	// diffSidesHeight is the height of the row that names the two sides.
	diffSidesHeight = 26
	// diffMarkWidth is the width of the bar at the start of a changed unified line.
	diffMarkWidth = 3
	// diffConnectorWidth is the width of the band between the two sides that joins the rows
	// of a difference.
	diffConnectorWidth = 12
	// diffRulerWidth is the width of the strip beside the list that marks where the
	// differences are in the whole file.
	diffRulerWidth = 8
	// diffTint is the opacity of the background of a changed line.
	diffTint = 0.16
	// diffModeWidth is the width of the drop-down that switches the modes.
	diffModeWidth = 104
)

// diffView declares Diff tab t in the group that shows it.
func (a *App) diffView(c ui.C, p *project, t *diffTab) {
	ui.Column(c.Key("diff" + strconv.Itoa(t.id))).Fill().Background(a.colors.Editor).Children(func() {
		a.diffToolbar(c, p, t)
		ui.Divider(c)
		a.diffSides(c, t)
		ui.Divider(c)
		a.diffBody(c, p, t)
	})
}

// diffToolbar declares the buttons over the diff: the previous and the next difference, open
// the file, the previous and the next changed file, fold the unchanged lines, then the count of
// the differences and the mode.
func (a *App) diffToolbar(c ui.C, p *project, t *diffTab) {
	lang, size := a.language(), a.theme.Metrics.FontSizeS
	n := len(t.changes)
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, i18n.Shared(lang, "git.diff.previousDifference"), icons.ArrowUp, false, n == 0 || t.current <= 0) {
			c.After(func() { t.step(-1) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.diff.nextDifference"), icons.ArrowDown, false, n == 0 || t.current >= n-1) {
			c.After(func() { t.step(1) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.openFile"), icons.Pencil, false, strings.Contains(t.change.Status, "D")) {
			c.After(func() { a.openDiffFile(p, t) })
		}
		if len(t.files) > 1 {
			i := t.fileIndex()
			if a.gitIconButton(c, i18n.Shared(lang, "git.diff.previousFile"), icons.ChevronLeft, false, t.busy || i <= 0) {
				c.After(func() { a.stepFile(p, t, -1) })
			}
			count := i18n.SharedFormat(lang, "git.log.filesCount", map[string]string{"count": strconv.Itoa(len(t.files))})
			ui.Text(c, count).FontSize(size).Color(a.colors.Subtle).Shrink(0)
			if a.gitIconButton(c, i18n.Shared(lang, "git.diff.nextFile"), icons.ChevronRight, false, t.busy || i < 0 || i >= len(t.files)-1) {
				c.After(func() { a.stepFile(p, t, 1) })
			}
		}
		if a.gitIconButton(c, i18n.Shared(lang, "native.collapseUnchangedFragments"), icons.FoldVertical, !t.whole, t.file == nil) {
			c.After(func() { a.setDiffMode(p, t, t.split, !t.whole) })
		}
		ui.Spacer(c)
		if t.note != "" {
			ui.Text(c, t.note).FontSize(size).Color(a.colors.Warning).Ellipsis().Shrink(1)
		}
		if t.file != nil {
			count := i18n.Shared(lang, "git.diff.oneDifference")
			if n != 1 {
				count = i18n.SharedFormat(lang, "git.diff.differences", map[string]string{"count": strconv.Itoa(n)})
			}
			ui.Text(c, count).FontSize(size).Color(a.colors.Subtle).Shrink(0)
		}
		ui.Select(c, &t.split, []bool{true, false}, func(split bool) string {
			if split {
				return i18n.Shared(lang, "git.diff.split")
			}
			return i18n.Shared(lang, "git.diff.unified")
		}).Label(i18n.Shared(lang, "desktop.gitReview.diffTab")).Width(diffModeWidth).Shrink(0)
		// The rows of this paint are laid out for the mode they were built for; the pick
		// takes effect after it.
		if t.split != t.builtSplit {
			split := t.split
			t.split = t.builtSplit
			c.After(func() { a.setDiffMode(p, t, split, t.whole) })
		}
	})
}

// diffSideLabels name the two sides of the tab: the parent and the commit, HEAD or the index
// and the working tree, or nothing and the working tree for an untracked file.
func (a *App) diffSideLabels(t *diffTab) (left, right string) {
	lang := a.language()
	head, index, worktree := i18n.Shared(lang, "native.head"), i18n.Shared(lang, "git.diff.indexVersion"), i18n.Shared(lang, "git.saved.worktree")
	switch {
	case t.commit != "":
		return shortHash(t.commit) + "^", shortHash(t.commit)
	case t.untracked():
		return i18n.Shared(lang, "git.diff.emptyRevision"), worktree
	case t.staged:
		return head, index
	case t.plan != nil:
		return head, worktree
	}
	return index, worktree
}

// diffSides declares the row that names the two sides: side by side over each half, one after
// the other over the unified lines. A side that cannot be edited shows a lock.
func (a *App) diffSides(c ui.C, t *diffTab) {
	left, right := a.diffSideLabels(t)
	original := t.change.Path
	if t.change.OriginalPath != "" {
		original = t.change.OriginalPath
	}
	ui.Row(c).Height(diffSidesHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Background(a.colors.Panel).Children(func() {
		if t.split {
			ui.Row(c).Grow(1).Basis(0).Items(ui.Center).Gap(6).Children(func() { a.diffSide(c, left, original, true) })
			ui.Row(c).Grow(1).Basis(0).Items(ui.Center).Gap(6).Children(func() { a.diffSide(c, right, t.change.Path, t.readOnly()) })
			ui.Row(c).Width(diffRulerWidth).Shrink(0)
			return
		}
		a.diffSide(c, left, "", true)
		a.diffSide(c, right, t.change.Path, t.readOnly())
	})
}

// diffSide declares the name of one side: a lock when it is read only, the label, and the path
// of the file on that side when there is one to show.
func (a *App) diffSide(c ui.C, label, path string, locked bool) {
	size := a.theme.Metrics.FontSizeS
	if locked {
		ui.Icon(c, icons.Lock).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
	}
	ui.Text(c, label).FontSize(size).Weight(gfx.WeightMedium).Shrink(0)
	if path != "" {
		ui.Text(c, path).FontSize(size).Color(a.colors.Subtle).Ellipsis().Shrink(1)
	}
}

// diffBody declares what the tab shows under its names: the rows of the file with the ruler of
// its differences, or a message while it is read, when it failed, and for a file without lines.
func (a *App) diffBody(c ui.C, p *project, t *diffTab) {
	lang := a.language()
	switch {
	case t.loading && t.file == nil:
		a.gitEmpty(c, i18n.Shared(lang, "git.loadingDiff"))
	case t.err != "":
		a.panelMessage(c, t.err, a.theme.Danger)
	case t.file == nil:
		a.gitEmpty(c, i18n.Shared(lang, "git.diff.noDifferences"))
	case t.file.IsBinary:
		a.gitEmpty(c, i18n.SharedFormat(lang, "git.binaryDiffDescription", map[string]string{"name": t.change.Path}))
	default:
		if t.ruler == nil {
			t.ruler = func(d *ui.DrawContext) { a.drawDiffRuler(d, t) }
		}
		label := i18n.Shared(lang, "git.diff.title") + " " + t.change.Path
		// The list is a container without an identity, so the row around it is named to take the
		// focus of the tab.
		body := ui.Row(c).Fill().Hit(ui.ID(c.Key("diffbody"+strconv.Itoa(t.id))), label)
		ui.FocusBind(body, &a.focus, focusTarget{diff: t.id})
		body.Children(func() {
			ui.List(c, &t.list, len(t.items), func(row ui.ListRow) { a.diffRow(row, p, t) }).
				Grow(1).FillHeight().Background(a.colors.Editor).Label(label)
			ui.Column(c).Width(diffRulerWidth).FillHeight().Shrink(0).Draw(t.ruler)
		})
	}
}

// diffRow declares one row of the list: a block's header, a fold, or a line.
func (a *App) diffRow(row ui.ListRow, p *project, t *diffTab) {
	if t.file == nil || row.Index >= len(t.items) {
		return
	}
	item, c := t.items[row.Index], row.C
	box := row.Element.FillWidth().Height(reviewRowHeight).Items(ui.Center)
	switch {
	case item.block != nil:
		box.Height(reviewBlockHeight).Gap(6).PadX(8).Background(a.colors.Hover).Children(func() { a.diffBlockHeader(c, p, t, item) })
	case item.fold > 0:
		text := i18n.SharedFormat(a.language(), "native.lldUnchangedLines", map[string]string{"arg1": strconv.Itoa(item.fold)})
		box.Height(diffFoldHeight).Gap(6).PadX(8).Background(a.colors.Hover).Children(func() {
			ui.Icon(c, icons.UnfoldVertical).Size(shellIconSize, shellIconSize).Color(a.colors.Subtle).Shrink(0)
			ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
		})
		if box.Clicked() {
			at := item.at
			c.After(func() { t.expand(at) })
		}
	case item.row >= 0 && item.row < len(t.file.Rows):
		a.diffSplitRow(c, box, t.file.Rows[item.row])
	case item.line >= 0 && item.line < len(t.file.Lines):
		a.diffUnifiedRow(c, box, t.file.Lines[item.line])
	}
}

// diffMark is the color that marks a line or a row of the kind: green for an added one, gray
// for a removed one, blue for a changed one; ok is false for any other.
func (a *App) diffMark(kind string) (color gfx.Color, ok bool) {
	switch kind {
	case "added", "addition":
		return a.colors.Success, true
	case "removed", "removal":
		return a.colors.Subtle, true
	case "changed":
		return a.colors.Accent, true
	}
	return gfx.Color{}, false
}

// diffUnifiedRow declares one unified line: the bar of a changed one, the old and the new line
// number, and the text over the line's tint.
func (a *App) diffUnifiedRow(c ui.C, box ui.Box, l core.GitDiffLine) {
	size, text := a.theme.Metrics.FontSizeS, a.colors.Text
	mark, changed := a.diffMark(l.LineType)
	switch {
	case changed:
		box = box.Background(mark.WithAlpha(diffTint))
	case l.LineType == "header":
		box, text = box.Background(a.colors.Hover), a.colors.Accent
	}
	box.Gap(6).PadRight(8).Children(func() {
		bar := ui.Row(c).Width(diffMarkWidth).FillHeight().Shrink(0)
		if changed {
			bar.Background(mark)
		}
		ui.Text(c, lineNumber(l.OldLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
		ui.Text(c, lineNumber(l.NewLine)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd()
		ui.Text(c, l.Content).Mono().FontSize(size).Color(text).Ellipsis().Grow(1)
	})
}

// diffSplitRow declares one aligned row: the old text, the old number, the band that joins a
// difference across, the new number and the new text. Each side is tinted for what changed on
// it.
func (a *App) diffSplitRow(c ui.C, box ui.Box, r core.GitDiffRow) {
	size := a.theme.Metrics.FontSizeS
	text := a.colors.Text
	var left, right, band gfx.Color
	mark, changed := a.diffMark(r.Kind)
	switch {
	case r.Kind == "addition":
		right, band = mark.WithAlpha(diffTint), mark
	case r.Kind == "removal":
		left, band = mark.WithAlpha(diffTint), mark
	case changed:
		left, right, band = mark.WithAlpha(diffTint), mark.WithAlpha(diffTint), mark
	case r.Kind == "information":
		left, right, text = a.colors.Hover, a.colors.Hover, a.colors.Accent
	}
	side := func(color gfx.Color, value string) {
		cell := ui.Row(c).Grow(1).Basis(0).FillHeight().Items(ui.Center).PadX(8).Clip()
		if color.Alpha > 0 {
			cell = cell.Background(color)
		}
		cell.Children(func() { ui.Text(c, value).Mono().FontSize(size).Color(text).Ellipsis().Grow(1) })
	}
	number := func(n *int) {
		ui.Text(c, lineNumber(n)).Mono().FontSize(size).Color(a.colors.Subtle).Width(reviewNumberWidth).Shrink(0).TextEnd().PadRight(4)
	}
	box.Children(func() {
		side(left, r.Left)
		number(r.OldLine)
		connector := ui.Row(c).Width(diffConnectorWidth).FillHeight().Shrink(0)
		if band.Alpha > 0 {
			connector.Background(band.WithAlpha(diffTint * 2))
		}
		number(r.NewLine)
		side(right, r.Text())
	})
}

// diffBlockHeader declares the header over one block: a checkbox that stages or unstages it
// and, for a block Core allows to roll back, the rollback with its confirmation.
func (a *App) diffBlockHeader(c ui.C, p *project, t *diffTab, item diffItem) {
	lang, block := a.language(), item.block
	number := i18n.SharedFormat(lang, "desktop.gitReview.blockN", map[string]string{"n": strconv.Itoa(item.number)})
	label := i18n.Shared(lang, "git.diff.includeBlock")
	if block.Checked {
		label = i18n.Shared(lang, "git.diff.excludeBlock")
	}
	checked := block.Checked
	if ui.Checkbox(c, &checked, label).Label(label).Disabled(t.busy || !block.CanToggle).Clicked() {
		b := *block
		c.After(func() { a.toggleDiffBlock(p, t, b) })
	}
	ui.Text(c, number).Weight(gfx.WeightMedium).Shrink(0)
	ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Grow(1)
	if !block.CanRollback {
		return
	}
	if t.confirm == block.ID {
		ui.Text(c, i18n.SharedFormat(lang, "git.diff.rollbackHunkConfirm", map[string]string{"path": t.change.Path})).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Shrink(1)
		if ui.Button(c, i18n.Shared(lang, "git.rollback.confirm")).Destructive().Disabled(t.busy).Clicked() {
			id := block.ID
			c.After(func() { a.writeDiffBlock(p, t, id, core.DiffBlockRollback) })
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			c.After(func() { t.confirm = "" })
		}
		return
	}
	if ui.Button(c, i18n.Shared(lang, "git.diff.rollbackHunk")).Ghost().Disabled(t.busy).Clicked() {
		id := block.ID
		c.After(func() { t.confirm = id })
	}
}

// diffItemHeight is the height the list gives item.
func diffItemHeight(item diffItem) float32 {
	switch {
	case item.block != nil:
		return reviewBlockHeight
	case item.fold > 0:
		return diffFoldHeight
	}
	return reviewRowHeight
}

// drawDiffRuler paints, beside the list, a mark for every changed line where it is in the whole
// list, so the user sees where the differences are when the file is longer than the view.
func (a *App) drawDiffRuler(d *ui.DrawContext, t *diffTab) {
	r := d.Rect
	if t.file == nil || r.Height <= 0 {
		return
	}
	var total float32
	for _, item := range t.items {
		total += diffItemHeight(item)
	}
	if total <= 0 {
		return
	}
	scale := min(1, r.Height/total)
	var y float32
	for _, item := range t.items {
		h := diffItemHeight(item)
		kind := ""
		switch {
		case item.block != nil || item.fold > 0:
		case item.row >= 0 && item.row < len(t.file.Rows):
			kind = t.file.Rows[item.row].Kind
		case item.line >= 0 && item.line < len(t.file.Lines):
			kind = t.file.Lines[item.line].LineType
		}
		if color, ok := a.diffMark(kind); ok {
			d.Canvas.Fill(gfx.Rect{X: r.X + 1, Y: r.Y + y*scale, Width: r.Width - 2, Height: max(h*scale, 2)}, d.Fade(color))
		}
		y += h
	}
}
