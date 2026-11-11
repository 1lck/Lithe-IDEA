package workbench

import (
	"sort"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the body of a Diff tab: the toolbar that steps through the differences
// and the files and switches the modes, the names of the two sides, and the editors with the
// gap between them and the marks of the differences beside them. As in IDEA, side by side the
// before editor shows no numbers of its own: the gap shows them next to it, then joins each
// difference of the before side to the same difference of the after side with a band, and
// carries the rollback and the checkbox of the difference's block. The unified editor has a
// narrow gap before it with the blocks' controls. State and actions are in difftab.go.

const (
	// diffSidesHeight is the height of the row that names the two sides.
	diffSidesHeight = 26
	// diffRulerWidth is the width of the strip beside the editors that marks where the
	// differences are in the whole file.
	diffRulerWidth = 8
	// diffTint is the opacity of the background of a changed line.
	diffTint = 0.16
	// diffWordTint is the opacity of the background of the words of a changed line that differ
	// from the other side, over the line's own tint.
	diffWordTint = 0.28
	// diffBandWidth is the width of the part of the gap where a band joins a difference of the
	// before side to the after side.
	diffBandWidth = 36
	// diffNumberPad is the room on each side of the before side's numbers in the gap.
	diffNumberPad = 6
	// diffUnifiedGap is the width of the gap before the unified editor while the tab has blocks
	// to stage; diffMarkWidth is the width of the gap without them, and of the bar that marks a
	// difference in it.
	diffUnifiedGap = 36
	diffMarkWidth  = 3
	// diffControlSize is the size of a block's checkbox and of its rollback in the gap, and
	// diffControlPad the room between them and the gap's edges.
	diffControlSize = 14
	diffControlPad  = 3
)

// diffView declares Diff tab t in the group that shows it.
func (a *App) diffView(c ui.C, p *project, t *diffTab) {
	ui.Column(c.Key("diff" + strconv.Itoa(t.id))).Fill().Background(a.colors.Editor).Children(func() {
		a.diffToolbar(c, p, t)
		ui.Divider(c)
		if t.find.open && t.file != nil {
			a.diffFindBar(c, t)
		}
		a.diffSides(c, t)
		ui.Divider(c)
		a.diffBody(c, p, t)
	})
}

// diffToolbar declares the buttons over the diff: the previous and the next difference, open
// the file, the previous and the next changed file, fold the unchanged lines, then the count of
// the differences and the two modes. A rollback waiting for the user's word shows its question
// and its buttons in it.
func (a *App) diffToolbar(c ui.C, p *project, t *diffTab) {
	lang, size := a.language(), a.theme.Metrics.FontSizeS
	n := t.differences()
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
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.diffFind.open"), icons.Search, t.find.open, t.file == nil) {
			c.After(func() {
				if t.find.open {
					t.closeDiffFind()
				} else {
					t.find.open = true
				}
			})
		}
		ui.Spacer(c)
		if block := t.confirming(); block != nil {
			a.diffRollbackConfirm(c, p, t, *block)
		} else if t.note != "" {
			ui.Text(c, t.note).FontSize(size).Color(a.colors.Warning).Ellipsis().Shrink(1)
		}
		if t.file != nil {
			count := i18n.Shared(lang, "git.diff.oneDifference")
			if n != 1 {
				count = i18n.SharedFormat(lang, "git.diff.differences", map[string]string{"count": strconv.Itoa(n)})
			}
			ui.Text(c, count).FontSize(size).Color(a.colors.Subtle).Shrink(0)
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.diff.ignoreWhitespace"), icons.Eraser, t.ignoreSpace, t.stash != nil) {
			c.After(func() { a.setDiffWhitespace(p, t, !t.ignoreSpace) })
		}
		ui.Row(c).Shrink(0).Items(ui.Center).Gap(2).Label(i18n.Shared(lang, "desktop.gitReview.diffTab")).Children(func() {
			if a.gitIconButton(c, i18n.Shared(lang, "git.diff.split"), icons.Columns2, t.split, false) && !t.split {
				c.After(func() { a.setDiffMode(p, t, true, t.whole) })
			}
			if a.gitIconButton(c, i18n.Shared(lang, "git.diff.unified"), icons.Square, !t.split, false) && t.split {
				c.After(func() { a.setDiffMode(p, t, false, t.whole) })
			}
		})
	})
}

// confirming is the block whose rollback waits for the user's word, nil when none does or the
// plan no longer has it.
func (t *diffTab) confirming() *core.DiffBlock {
	if t.confirm == "" || t.plan == nil {
		return nil
	}
	for i := range t.plan.Blocks {
		if t.plan.Blocks[i].ID == t.confirm {
			return &t.plan.Blocks[i]
		}
	}
	return nil
}

// diffRollbackConfirm declares the question of a rollback and its two answers.
func (a *App) diffRollbackConfirm(c ui.C, p *project, t *diffTab, block core.DiffBlock) {
	lang := a.language()
	question := i18n.SharedFormat(lang, "git.diff.rollbackHunkConfirm", map[string]string{"path": t.change.Path})
	ui.Text(c, question).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Shrink(1)
	if ui.Button(c, i18n.Shared(lang, "git.rollback.confirm")).Destructive().Disabled(t.busy).Clicked() {
		id := block.ID
		c.After(func() { a.writeDiffBlock(p, t, id, core.DiffBlockRollback) })
	}
	if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
		c.After(func() { t.confirm = "" })
	}
}

// diffSideLabels name the two sides of the tab: the stash's base and the stash, the parent and
// the commit, HEAD or the index and the working tree, or nothing and the working tree for an
// untracked file.
func (a *App) diffSideLabels(t *diffTab) (left, right string) {
	lang := a.language()
	head, index, worktree := i18n.Shared(lang, "native.head"), i18n.Shared(lang, "git.diff.indexVersion"), i18n.Shared(lang, "git.saved.worktree")
	switch {
	case t.stash != nil:
		return t.stash.label + "^", t.stash.label
	case t.compare != nil:
		if t.compare.target == nil {
			return t.compare.base.ShortName, worktree
		}
		return t.compare.base.ShortName, t.compare.target.ShortName
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

// diffSides declares the row that names the two sides: side by side over each editor, with the
// gap between them as wide as the editors', one after the other over the unified editor. A side
// that cannot be edited shows a lock.
func (a *App) diffSides(c ui.C, t *diffTab) {
	left, right := a.diffSideLabels(t)
	original := t.change.Path
	if t.change.OriginalPath != "" {
		original = t.change.OriginalPath
	}
	ui.Row(c).Height(diffSidesHeight).FillWidth().Shrink(0).Items(ui.Center).Background(a.colors.Panel).Children(func() {
		if t.split {
			ui.Row(c).Grow(1).Basis(0).Items(ui.Center).Gap(6).PadX(8).Clip().Children(func() { a.diffSide(c, left, original, true) })
			ui.Row(c).Width(a.diffGapWidth(t)).Shrink(0)
			ui.Row(c).Grow(1).Basis(0).Items(ui.Center).Gap(6).PadX(8).Clip().Children(func() { a.diffSide(c, right, t.change.Path, t.readOnly()) })
			ui.Row(c).Width(diffRulerWidth).Shrink(0)
			return
		}
		ui.Row(c).Grow(1).Items(ui.Center).Gap(6).PadX(8).Clip().Children(func() {
			a.diffSide(c, left, "", true)
			a.diffSide(c, right, t.change.Path, t.readOnly())
		})
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

// diffGapWidth is the width of the gap of the tab: side by side the before side's numbers and
// the band, unified the room of the blocks' controls, or only a mark when there are none.
func (a *App) diffGapWidth(t *diffTab) float32 {
	if t.split {
		cellW := t.cellW
		if cellW <= 0 {
			// Before the gap measured the font: about the advance of a monospaced cell.
			cellW = a.editorFont().Size * 0.6
		}
		return float32(max(t.numberCells, 1))*cellW + 2*diffNumberPad + diffBandWidth
	}
	if t.plan != nil && len(t.plan.Blocks) > 0 {
		return diffUnifiedGap
	}
	return 2 * diffMarkWidth
}

// diffBody declares what the tab shows under its names: the editors with the gap and the ruler
// of the differences, or a message while it is read, when it failed, and for a file without
// lines.
func (a *App) diffBody(c ui.C, p *project, t *diffTab) {
	lang := a.language()
	switch {
	case t.loading && t.file == nil:
		a.gitEmpty(c, i18n.Shared(lang, "git.loadingDiff"))
	case t.err != "":
		a.panelMessage(c, t.err, a.theme.Danger)
	case t.file == nil || t.layout == nil || t.after == nil:
		a.gitEmpty(c, i18n.Shared(lang, "git.diff.noDifferences"))
	case t.file.IsBinary:
		a.gitEmpty(c, i18n.SharedFormat(lang, "git.binaryDiffDescription", map[string]string{"name": t.change.Path}))
	default:
		if t.ruler == nil {
			t.ruler = func(d *ui.DrawContext) { a.drawDiffRuler(d, t) }
		}
		if t.gapDraw == nil {
			t.gap = ui.Handlers{
				Role: gfx.RoleGroup,
				// The wheel over the gap scrolls the after side, and the before side follows.
				Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
					if t.after == nil {
						return gfx.EventResult{}
					}
					result, _ := t.after.view.Scroll(event)
					return result
				},
			}
			t.gapDraw = func(d *ui.DrawContext) { a.drawDiffGap(d, p, t) }
		}
		id := strconv.Itoa(t.id)
		label := i18n.Shared(lang, "git.diff.title") + " " + t.change.Path
		ui.Row(c).Fill().Children(func() {
			if t.layout.split && t.before != nil {
				a.diffEditorControl(c, t, t.before, "diffbefore"+id, false)
			}
			ui.Control(c.Part("diffgap"+id), label, &t.gap).Width(a.diffGapWidth(t)).FillHeight().Shrink(0).
				Background(a.colors.Editor).Clip().Draw(t.gapDraw)
			a.diffEditorControl(c, t, t.after, "diffafter"+id, true)
			ui.Column(c).Width(diffRulerWidth).FillHeight().Shrink(0).Draw(t.ruler)
		})
	}
}

// diffEditorControl declares the control of editor e of tab t under name. The editor paints
// into it and takes keys, pointer, wheel and typing through its handlers; the after side's
// control is the one that takes the tab's keyboard.
func (a *App) diffEditorControl(c ui.C, t *diffTab, e *diffEditor, name string, focus bool) {
	// A part names the next element only, so it is given again for the control: its identity is
	// the one the view paints its hits under.
	e.hit = ui.ID(c.Part(name))
	box := ui.Control(c.Part(name), e.label, &e.input).Grow(1).Basis(0).FillHeight().Draw(e.draw)
	if focus {
		ui.FocusBind(box, &a.focus, focusTarget{diff: t.id})
	}
}

// diffPalette is the colors a Diff tab marks its lines with: an added, a removed and a changed
// line, the placeholder of a fold and the rules around it.
type diffPalette struct {
	added, removed, modified gfx.Color
}

// diffPalette is the colors of the current look.
func (a *App) diffPalette() diffPalette {
	return diffPalette{added: a.colors.Success, removed: a.colors.Subtle, modified: a.colors.Accent}
}

// color is the color that marks a line of kind, false for a line that did not change.
func (p diffPalette) color(kind diffKind) (gfx.Color, bool) {
	switch kind {
	case diffAdded:
		return p.added, true
	case diffRemoved:
		return p.removed, true
	case diffModified:
		return p.modified, true
	}
	return gfx.Color{}, false
}

// drawDiffEditor paints editor e of tab t: the before side when before is set. The view takes
// the font and the labels, notes and tints of the layout, the two sides are put in step, and
// a paint that moved the view, to a difference stepped to or back in range, asks for another,
// so the other side and the gap follow it.
func (a *App) drawDiffEditor(dc *ui.DrawContext, t *diffTab, e *diffEditor, before bool) {
	v := e.view
	v.BindWithoutMinimap(e.hit, e.input.Parts())
	if before {
		// The after side's bar scrolls both sides; a bar here would stand against the gap.
		v.HideVerticalBar()
	}
	v.SetFont(a.editorFont())
	v.SetWrap(false)
	v.SetMessages(a.editorMessages())
	a.decorateDiffEditor(t, e, before)
	a.followDiffScroll(t, dc.Rect.Height)
	x, y := v.ScrollOffset()
	v.Paint(dc.Canvas, dc.Rect, a.editorLook())
	if nx, ny := v.ScrollOffset(); nx != x || ny != y {
		a.invalidator.Invalidate()
	}
}

// decorateDiffEditor hands editor e the labels, notes, tints and word tints of its side of the
// tab's layout, when the layout or the colors changed since it last did. Side by side the before
// side shows no numbers: the gap shows them.
func (a *App) decorateDiffEditor(t *diffTab, e *diffEditor, before bool) {
	l, palette := t.layout, a.diffPalette()
	if l == nil || (e.decorated == l && e.palette == palette) {
		return
	}
	e.decorated, e.palette = l, palette
	pane := &l.after
	if before {
		pane = &l.before
	}
	v := e.view
	if before {
		v.SetLineLabels([]string{})
	} else {
		v.SetLineLabels(pane.labels)
	}
	v.SetLineAnnotations(pane.notes)
	// A placeholder has no tint: its note, with an icon and a rule, marks it, as IDEA draws a
	// fold.
	highlights := make([]editorview.LineHighlight, 0, len(pane.marks))
	for _, m := range pane.marks {
		color, ok := palette.color(m.kind)
		switch {
		case !ok:
		case m.boundary:
			highlights = append(highlights, editorview.LineHighlight{StartLine: m.span.start, Color: color, Boundary: true})
		default:
			highlights = append(highlights, editorview.LineHighlight{StartLine: m.span.start, EndLine: m.span.end - 1, Color: color.WithAlpha(diffTint)})
		}
	}
	v.SetLineHighlights(highlights)
	words := make([]editorview.InlineHighlight, 0, len(pane.words))
	for _, w := range pane.words {
		if color, ok := palette.color(w.kind); ok {
			words = append(words, editorview.InlineHighlight{Line: w.line, Start: w.start, End: w.end, Color: color.WithAlpha(diffWordTint)})
		}
	}
	v.SetInlineHighlights(words)
}

// drawDiffGap paints the gap of tab t and declares the controls of the blocks in it. Side by
// side it shows the numbers of the before side's lines in view next to the before editor, and
// joins each difference in view across to the after side with a band; unified it marks each
// difference with a bar. A block's rollback is at the top of its lines on the before side, its
// checkbox at the top of them on the after side. A click on one of them, delivered in this
// paint, toggles the block or asks to confirm its rollback.
func (a *App) drawDiffGap(d *ui.DrawContext, p *project, t *diffTab) {
	l, r, canvas := t.layout, d.Rect, d.Canvas
	if l == nil || t.after == nil || r.Width <= 0 || r.Height <= 0 {
		return
	}
	if i, ok := canvas.ClickedIn(t.gap.Parts()); ok {
		a.diffGapClicked(p, t, i)
	}
	after := t.after.view
	var before *editorview.View
	if l.split && t.before != nil {
		before = t.before.view
	}
	if after.LineHeight() <= 0 || (before != nil && before.LineHeight() <= 0) {
		// The editors were not painted yet, so their lines have no place: the next paint draws
		// the gap.
		a.invalidator.Invalidate()
		return
	}
	palette := a.diffPalette()
	canvas.Clip(r)
	defer canvas.Unclip()
	if before == nil {
		a.drawUnifiedGap(canvas, r, t, after, palette)
		return
	}
	font := a.editorFont()
	cellW, cellH := canvas.MonoCellSize(font.Size, font.Face)
	if cellW != t.cellW {
		// The gap was laid out for another cell width: the next paint lays it out for this one.
		t.cellW = cellW
		a.invalidator.Invalidate()
	}
	numbers := r.Width - diffBandWidth
	x0, x1 := r.X+numbers, r.X+r.Width
	bottom := r.Y + r.Height
	// The tints and rules of the differences continue across the numbers, under them.
	first := sort.Search(len(l.fragments), func(i int) bool {
		f := l.fragments[i]
		return before.LineTop(f.before.end) >= r.Y || after.LineTop(f.after.end) >= r.Y
	})
	for i := first; i < len(l.fragments); i++ {
		f := l.fragments[i]
		bt, bb := before.LineTop(f.before.start), before.LineTop(f.before.end)
		at, ab := after.LineTop(f.after.start), after.LineTop(f.after.end)
		if bt > bottom && at > bottom {
			break
		}
		color, ok := palette.color(f.kind)
		if !ok {
			continue
		}
		if f.before.empty() {
			canvas.Fill(gfx.Rect{X: r.X, Y: bt, Width: numbers, Height: 1}, color)
		} else {
			canvas.Fill(gfx.Rect{X: r.X, Y: bt, Width: numbers, Height: bb - bt}, color.WithAlpha(diffTint))
		}
		a.drawDiffBand(canvas, r, x0, x1, bt, bb, at, ab, color)
		a.drawDiffBlockControls(canvas, t, i, f, x0, x1, bt, at, before.LineHeight())
	}
	// The numbers of the before side's lines in view, on the cell grid with their right edge on
	// the numbers' column, as the editor draws its own.
	look := a.editorLook()
	style := gfx.TextStyle{Size: font.Size, Color: look.Subtle, Mono: true, MonoFace: font.Face}
	lineH := before.LineHeight()
	_, scroll := before.ScrollOffset()
	right := r.X + numbers - diffNumberPad
	for line := max(int(scroll/lineH), 0); line < l.before.lineCount(); line++ {
		y := before.LineTop(line)
		if y > bottom {
			break
		}
		label := l.before.labels[line]
		n := len(label)
		if n == 0 {
			continue
		}
		run := [1]gfx.TextRun{{Bytes: int32(n), Cells: int32(n), Color: style.Color}}
		rect := gfx.Rect{X: right - float32(n)*cellW, Y: y + (lineH-cellH)/2, Width: float32(n)*cellW + 1, Height: cellH}
		canvas.LabelRuns(label, rect, style, cellW, run[:])
	}
}

// drawDiffBand fills the band that joins a difference across the gap, from the before side's
// lines from bt to bb at x0 to the after side's from at to ab at x1, and draws its two edges.
// A side without lines of the difference has its edges meet at the rule where they would be.
func (a *App) drawDiffBand(canvas *gfx.Canvas, r gfx.Rect, x0, x1, bt, bb, at, ab float32, color gfx.Color) {
	// The path is laid out in the gap's own box, so DrawPath maps it onto the gap one to one.
	x0, x1 = x0-r.X, x1-r.X
	bt, bb, at, ab = bt-r.Y, bb-r.Y, at-r.Y, ab-r.Y
	mid := (x0 + x1) / 2
	path := canvas.PathBuilder()
	path.MoveTo(x0, bt)
	path.CubicTo(mid, bt, mid, at, x1, at)
	path.LineTo(x1, ab)
	path.CubicTo(mid, ab, mid, bb, x0, bb)
	path.Close()
	canvas.DrawPath(path.Path(r.Width, r.Height), r, gfx.PathStyle{Fill: color.WithAlpha(diffTint)})
	for _, edge := range [2][2]float32{{bt, at}, {bb, ab}} {
		path = canvas.PathBuilder()
		path.MoveTo(x0, edge[0])
		path.CubicTo(mid, edge[0], mid, edge[1], x1, edge[1])
		canvas.DrawPath(path.Path(r.Width, r.Height), r, gfx.PathStyle{Stroke: color, StrokeWidth: 1})
	}
}

// drawUnifiedGap paints the gap before the unified editor: a bar beside each difference in view
// and its block's controls.
func (a *App) drawUnifiedGap(canvas *gfx.Canvas, r gfx.Rect, t *diffTab, after *editorview.View, palette diffPalette) {
	l, bottom := t.layout, r.Y+r.Height
	first := sort.Search(len(l.fragments), func(i int) bool { return after.LineTop(l.fragments[i].after.end) >= r.Y })
	for i := first; i < len(l.fragments); i++ {
		f := l.fragments[i]
		top, end := after.LineTop(f.after.start), after.LineTop(f.after.end)
		if top > bottom {
			break
		}
		if color, ok := palette.color(f.kind); ok {
			canvas.Fill(gfx.Rect{X: r.X + r.Width - diffMarkWidth, Y: top, Width: diffMarkWidth, Height: max(end-top, 2)}, color)
		}
		a.drawDiffBlockControls(canvas, t, i, f, r.X, r.X+r.Width-diffMarkWidth, top, top, after.LineHeight())
	}
}

// drawDiffBlockControls declares and paints the controls of the block of fragment i, the k-th
// difference: its rollback at the left of the gap, from x0, level with the line at bt, and its
// checkbox at the right, up to x1, level with the line at at. A difference without a block has
// none.
func (a *App) drawDiffBlockControls(canvas *gfx.Canvas, t *diffTab, i int, f diffFragment, x0, x1, bt, at, lineH float32) {
	block := f.block
	if block == nil {
		return
	}
	lang := a.language()
	number := i18n.SharedFormat(lang, "desktop.gitReview.blockN", map[string]string{"n": strconv.Itoa(f.number)})
	parts := t.gap.Parts()
	inset := (lineH - diffControlSize) / 2
	box := gfx.Rect{X: x1 - diffControlPad - diffControlSize, Y: at + inset, Width: diffControlSize, Height: diffControlSize}
	toggle := i18n.Shared(lang, "git.diff.includeBlock")
	if block.Checked {
		toggle = i18n.Shared(lang, "git.diff.excludeBlock")
	}
	disabled := t.busy || !block.CanToggle
	canvas.HitWithOptions(parts.At(2*i), box, number+" "+toggle, gfx.HitOptions{
		Role: gfx.RoleCheckbox, Checked: block.Checked, Mixed: block.Indeterminate, Disabled: disabled, Cursor: gfx.PointerCursorHand,
	})
	// The box looks as the checkboxes of the change lists do, opaque over the band.
	state := gfx.State{Checked: block.Checked, Mixed: block.Indeterminate, Disabled: disabled}
	look := components.CheckboxRecipe(a.theme, state)
	fill := look.Fill
	if fill.Alpha < 1 {
		fill = fill.Over(a.colors.Editor)
	}
	canvas.RoundedBorder(box, look.Radius, 1, look.Border, fill)
	components.PaintCheckboxMark(canvas, box, state, look.Mark)
	if !block.CanRollback {
		return
	}
	undo := gfx.Rect{X: x0 + diffControlPad, Y: bt + inset, Width: diffControlSize, Height: diffControlSize}
	canvas.HitWithOptions(parts.At(2*i+1), undo, number+" "+i18n.Shared(lang, "git.diff.rollbackHunk"), gfx.HitOptions{
		Role: gfx.RoleButton, Disabled: t.busy, Cursor: gfx.PointerCursorHand,
	})
	tint := a.colors.Subtle
	if t.confirm == block.ID {
		tint = a.colors.Warning
	}
	canvas.DrawIcon(icons.Undo2, undo, tint)
}

// diffGapClicked does what a click on control part of the gap of tab t asks: an even part is
// the checkbox of the block of fragment part/2 and stages or unstages it, an odd one its
// rollback and asks the user to confirm it.
func (a *App) diffGapClicked(p *project, t *diffTab, part int) {
	l := t.layout
	if l == nil || t.busy || part/2 >= len(l.fragments) {
		return
	}
	block := l.fragments[part/2].block
	switch {
	case block == nil:
	case part%2 == 0:
		if block.CanToggle {
			a.toggleDiffBlock(p, t, *block)
		}
	case block.CanRollback:
		t.confirm = block.ID
	}
}

// drawDiffRuler paints, beside the editors, a mark for every difference where it is in the
// whole after side, so the user sees where the differences are when the file is longer than the
// view. A difference that only removed lines is a thin mark where they were.
func (a *App) drawDiffRuler(d *ui.DrawContext, t *diffTab) {
	r, l := d.Rect, t.layout
	if l == nil || r.Height <= 0 {
		return
	}
	total := float32(l.after.lineCount())
	scale := r.Height / total
	if t.after != nil {
		if lineH := t.after.view.LineHeight(); lineH > 0 {
			// A file shorter than the view is marked where its lines are.
			scale = min(scale, lineH)
		}
	}
	palette := a.diffPalette()
	for _, f := range l.fragments {
		color, ok := palette.color(f.kind)
		if !ok {
			continue
		}
		top := float32(f.after.start) * scale
		height := max(float32(f.after.end-f.after.start)*scale, 2)
		d.Canvas.Fill(gfx.Rect{X: r.X + 1, Y: r.Y + top, Width: r.Width - 2, Height: height}, d.Fade(color))
	}
}
