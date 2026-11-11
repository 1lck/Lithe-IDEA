package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// The Console tab is one Page: the toolbar with the search over the list of rows that
// gitconsole.go flattens. The rows are drawn in the run output's font (fonts.go), so the
// console reads like the run output beside it and, with the default fonts, like the editor.
// A header's stamp is subtle, its repository is in the accent color, and its temporary
// configuration is the toggle of its fold: a click on it opens or closes it. Other folds have
// their toggle after the row, and a header its running badge.
//
// The rows are broken into lines or cut to the list's width here, by the cells of the font,
// rather than by ui Wrap and Ellipsis, and each stretch is given the width its cells take:
// Viva measures a fixed-pitch text one cell a character and breaks it where the
// proportional font would, so wide characters such as Chinese ones would overlap and lines
// would run past the edge (vivaui/viva#187). The workaround goes when that is fixed.

const (
	// consoleRowPadX is the room on either side of a row, and consoleRowGap the room between
	// its text, its badge and its toggle.
	consoleRowPadX = 8
	consoleRowGap  = 6
	// consoleMenuWidth is the width of a record's context menu.
	consoleMenuWidth = 220
	// consoleEllipsis ends a line cut short; it takes one cell.
	consoleEllipsis = "…"
)

// consolePageView declares the body of the Console tab: the toolbar over the rows, or the
// empty message when the console holds no command.
func (a *App) consolePageView(c ui.C) {
	v := &a.consoleView
	if v.drawRow == nil {
		v.list.Key, v.list.Label = v.rowKey, v.rowLabel
		v.drawRow = a.drawConsoleRow
		v.measure = v.measureWidth
	}
	a.syncConsole()
	ui.Column(c).Fill().Background(a.colors.Editor).Draw(v.measure).Children(func() {
		a.drawConsoleToolbar(c)
		ui.Divider(c)
		if len(v.snapshot.Records) == 0 {
			a.gitEmpty(c, a.text.Console.Empty)
			return
		}
		a.drawConsoleList(c)
	})
}

// drawConsoleToolbar declares the toolbar: the search with its count and the buttons that
// step through the hits, then the view and console actions.
func (a *App) drawConsoleToolbar(c ui.C) {
	v, t := &a.consoleView, &a.text.Console
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.TextFieldID(c, consoleSearchID, &v.search, t.Find, t.Find).MinWidth(150).Grow(1).MaxWidth(320)
		if v.searchFor != "" && v.counted {
			if v.total == 0 {
				a.drawConsoleCount(c, t.NoMatches)
			} else {
				a.drawConsoleCount(c, t.Matches(v.total))
				if v.total > len(v.hits) {
					a.drawConsoleCount(c, t.SearchLimit(len(v.hits)))
				}
			}
		}
		noHits := len(v.hits) == 0
		if a.gitIconButton(c, t.PreviousMatch, icons.ChevronUp, false, noHits) {
			c.After(func() { a.stepConsoleMatch(-1) })
		}
		if a.gitIconButton(c, t.NextMatch, icons.ChevronDown, false, noHits) {
			c.After(func() { a.stepConsoleMatch(1) })
		}
		if a.gitIconButton(c, t.CloseSearch, icons.X, false, v.searchFor == "") {
			c.After(a.closeConsoleSearch)
		}
		ui.Spacer(c)
		empty := len(v.snapshot.Records) == 0
		if a.gitIconButton(c, t.Wrap, icons.WrapText, v.wrap, false) {
			c.After(a.toggleConsoleWrap)
		}
		if a.gitIconButton(c, t.ScrollToEnd, icons.ArrowDownToLine, false, empty) {
			c.After(a.consoleScrollToEnd)
		}
		if a.gitIconButton(c, t.Stop, icons.Square, false, !v.snapshot.Running) {
			c.After(a.stopConsole)
		}
		if a.gitIconButton(c, t.Clear, icons.Eraser, false, empty) {
			c.After(a.clearConsole)
		}
		if a.gitIconButton(c, t.CopyAll, icons.Copy, false, empty) {
			c.After(a.copyConsoleAll)
		}
	})
}

// drawConsoleCount declares a note of the search's count beside the search field.
func (a *App) drawConsoleCount(c ui.C, value string) {
	ui.Text(c, value).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
}

// drawConsoleList declares the rows. The list follows its end while the user leaves it
// there; a step to a hit scrolls it away from the end, which Follow would undo in the same
// layout, so the area is told it was left there.
func (a *App) drawConsoleList(c ui.C) {
	v := &a.consoleView
	v.font = a.outputFont()
	v.cellW, _ = c.Canvas().MonoCellSize(v.font.Size, v.font.face)
	v.lineH = v.font.lineHeight(c.Canvas())
	area := ui.List(c, &v.list, len(v.rows), v.drawRow).Label(a.text.Git.Console).Grow(1).FillWidth().Follow(true)
	if v.detach {
		v.detach = false
		s := area.ScrollState()
		s.ScrollTo(s.Offset)
	}
}

// measureWidth records the width of the Console tab, which the list fills, as it is drawn.
// The rows were laid out for the width before, so a frame that finds it changed asks for one
// more, laid out for the new one.
func (v *consoleView) measureWidth(d *ui.DrawContext) {
	if width := d.Rect.Width; width != v.width {
		v.width = width
		d.Canvas.RequestFrame()
	}
}

// drawConsoleRow declares one row: its text in the row's colors, broken into lines or cut to
// the list's width, then its badge and the toggle of a fold that is not inline, with the
// context menu of its record. The current hit's row is drawn selected and the other rows with
// a hit are tinted.
func (a *App) drawConsoleRow(row ui.ListRow) {
	v := &a.consoleView
	if row.Index < 0 || row.Index >= len(v.rows) {
		return
	}
	r := &v.rows[row.Index]
	c := row.C
	item := row.Element.FillWidth().MinHeight(v.lineH).PadX(consoleRowPadX).Gap(consoleRowGap).Items(ui.Center)
	switch {
	case row.Index == v.hitRow:
		item.Background(a.colors.Selection)
	case r.matched:
		item.Background(a.colors.Hover)
	}
	if r.record >= 0 {
		ui.ContextMenu(c, row.Element, a.consoleMenu(c, r.record))
	}
	item.Children(func() {
		v.pieces = layoutConsoleRow(v.pieces[:0], r.text, r.spans, a.consoleCells(c.Canvas(), r), v.wrap)
		pieces := v.pieces
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Clip().Children(func() {
			for len(pieces) > 0 {
				n := 1
				for n < len(pieces) && pieces[n].line == pieces[0].line {
					n++
				}
				line := pieces[:n]
				pieces = pieces[n:]
				ui.Row(c.KeyInt(line[0].line)).Items(ui.Center).Children(func() {
					a.drawConsolePieces(c, r, line)
				})
			}
		})
		if r.badge != "" {
			ui.Text(c, r.badge).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		}
		if r.toggle == "" || r.inline {
			return
		}
		// The toggle is named by the row's part, so each row's toggle is a control of its own.
		fc := c.Part("fold")
		id := ui.ID(fc)
		toggle := ui.Row(fc).Shrink(0).Items(ui.Center).
			HitWith(id, r.toggle, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
		toggle.Children(func() {
			ui.Text(fc, r.toggle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent)
		})
		if toggle.Clicked() {
			fold, opening := r.fold, r.folded
			c.After(func() { a.toggleConsoleFold(fold, opening) })
		}
	})
}

// drawConsolePieces declares the pieces of one drawn line of row r, each in the run output's
// font, as wide as its cells and in the color of its kind. A piece of the configuration of a
// header is the toggle of its fold: it says what a click does to assistive technology, shows
// the hand and the accent color under the pointer, and opens or closes the fold.
func (a *App) drawConsolePieces(c ui.C, r *consoleRow, pieces []consolePiece) {
	v := &a.consoleView
	for _, piece := range pieces {
		box := ui.Text(c, piece.text).FontSize(v.font.Size).MonoFace(v.font.face).LineHeight(v.lineH).
			Width(float32(piece.cells) * v.cellW).Shrink(0).Color(a.consoleSpanColor(r.tone, piece.kind))
		if piece.kind != consoleSpanFold || !r.inline {
			continue
		}
		box.HitWith(ui.ID(c), r.toggle, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Color(a.colors.Accent))
		if box.Clicked() {
			fold, opening := r.fold, r.folded
			c.After(func() { a.toggleConsoleFold(fold, opening) })
		}
	}
}

// consoleCells is how many cells of the run output's font the text of row r has across: the
// list's width as last drawn, less the row's padding and the badge and toggle drawn after the
// text. It is 0, no limit, before the list has been drawn.
func (a *App) consoleCells(canvas *gfx.Canvas, r *consoleRow) int {
	v := &a.consoleView
	if v.width <= 0 || v.cellW <= 0 {
		return 0
	}
	room := v.width - 2*consoleRowPadX
	small := gfx.TextStyle{Size: a.theme.Metrics.FontSizeS, Weight: gfx.WeightRegular}
	if r.badge != "" {
		room -= consoleRowGap + canvas.TextWidthStyle(r.badge, small)
	}
	if r.toggle != "" && !r.inline {
		room -= consoleRowGap + canvas.TextWidthStyle(r.toggle, small)
	}
	// The small margin keeps a width of exactly n cells from rounding down to n-1.
	return max(int(room/v.cellW+0.001), 1)
}

// consolePiece is a stretch of a row's text drawn on one of its lines: the text, the kind of
// the span it is from, the line it is on and the cells it takes.
type consolePiece struct {
	text  string
	kind  consoleSpanKind
	line  int
	cells int
}

// layoutConsoleRow appends to dst the pieces text is drawn in on a row cells cells wide: the
// stretches of its spans, one span of text when spans is empty. With wrap set the text is
// broken onto as many lines as it takes, anywhere a line is full, as a terminal breaks it;
// otherwise it stays on one line, and a text too long for it is cut where the line less one
// cell is full and ends in consoleEllipsis, of the kind of the span it was cut in. A wide
// character that does not fit at the end of a line starts the next one. cells of zero or
// less, a width not known yet, keeps the text on one line, whole.
func layoutConsoleRow(dst []consolePiece, text string, spans []consoleSpan, cells int, wrap bool) []consolePiece {
	var whole [1]consoleSpan
	if len(spans) == 0 {
		whole[0] = consoleSpan{end: len(text), kind: consoleSpanText}
		spans = whole[:]
	}
	limit, cut := cells, false
	if !wrap && cells > 0 && consoleTextCells(text) > cells {
		limit, cut = cells-1, true
	}
	line, used, from := 0, 0, 0
	for _, span := range spans {
		end := min(span.end, len(text))
		if end <= from {
			continue
		}
		at, n := from, 0
		for i, r := range text[from:end] {
			i += from
			w := vivatext.CellWidth(r)
			if cells > 0 && used+w > limit && (cut || used > 0) {
				dst = appendConsolePiece(dst, text[at:i], span.kind, line, n)
				if cut {
					return append(dst, consolePiece{text: consoleEllipsis, kind: span.kind, line: line, cells: 1})
				}
				line, used, at, n = line+1, 0, i, 0
			}
			used += w
			n += w
		}
		dst = appendConsolePiece(dst, text[at:end], span.kind, line, n)
		from = end
	}
	return dst
}

// appendConsolePiece appends the piece of text to dst unless it is empty.
func appendConsolePiece(dst []consolePiece, text string, kind consoleSpanKind, line, cells int) []consolePiece {
	if text == "" {
		return dst
	}
	return append(dst, consolePiece{text: text, kind: kind, line: line, cells: cells})
}

// consoleTextCells is how many cells of a fixed-pitch font text takes.
func consoleTextCells(text string) int {
	cells := 0
	for _, r := range text {
		cells += vivatext.CellWidth(r)
	}
	return cells
}

// consoleSpanColor is the color of a stretch of kind in a row of tone: the stamp and the
// configuration are subtle and the repository in the accent color whatever the tone, and the
// rest takes the tone's.
func (a *App) consoleSpanColor(tone consoleTone, kind consoleSpanKind) gfx.Color {
	switch kind {
	case consoleSpanStamp, consoleSpanFold:
		return a.colors.Subtle
	case consoleSpanRepository:
		return a.colors.Accent
	}
	return a.consoleToneColor(tone)
}

// consoleToneColor is the color of a row's text in tone.
func (a *App) consoleToneColor(tone consoleTone) gfx.Color {
	switch tone {
	case consoleToneSubtle:
		return a.colors.Subtle
	case consoleToneError:
		return a.theme.Danger
	}
	return a.colors.Text
}

// consoleMenu declares the context menu of the record at index of the snapshot: copy its
// command, its output or the directory it ran in. The values are taken while the menu is
// declared, because the snapshot may change before the action runs.
func (a *App) consoleMenu(c ui.C, index int) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		v, t := &a.consoleView, &a.text.Console
		if index < 0 || index >= len(v.snapshot.Records) {
			return
		}
		r := &v.snapshot.Records[index]
		menu.WidthRange(consoleMenuWidth, consoleMenuWidth)
		if menu.Item(t.CopyCommand).Disabled(len(r.Arguments) == 0).Clicked() {
			command := consoleCommand(r)
			c.After(func() { a.copyConsoleRecord("copyCommand", command) })
		}
		if menu.Item(t.CopyOutput).Disabled(len(r.Lines) == 0).Clicked() {
			output := consoleOutput(r)
			c.After(func() { a.copyConsoleRecord("copyOutput", output) })
		}
		if menu.Item(t.CopyPath).Disabled(r.Root == "").Clicked() {
			root := r.Root
			c.After(func() { a.copyConsoleRecord("copyPath", root) })
		}
	}
}
