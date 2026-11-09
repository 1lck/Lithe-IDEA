package termview

import (
	"math"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// Paint draws the terminal into area: the ground, the character grid with its cursor and
// selection, and the scrollbar over the right edge. It also lays the grid out, so the screen
// and the shell always have the size of the area they are painted in, and it starts the
// shell on the first paint, once that size is known.
func (v *View) Paint(canvas *gfx.Canvas, area gfx.Rect, look Look) {
	v.clock = canvas.Now()
	// The cell is measured on this canvas, since the display scale decides the width. Nothing
	// can be laid out before the font has a size.
	cellW, cellH := canvas.MonoCellSize(fontSize, v.face)
	v.cellW, v.cellH = cellW, cellH
	if cellW <= 0 || cellH <= 0 {
		return
	}
	v.fit(geometry{
		area: area,
		left: area.X + padX,
		top:  area.Y + padTop,
		cols: max(int((area.Width-2*padX)/cellW), minCols),
		rows: max(int((area.Height-padTop-padBottom)/cellH), minRows),
	})
	v.applyLook(look)
	v.ensureStarted()
	// A selection dragged past the top or bottom edge scrolls on the frames paintGrid asks
	// for, before the rows of this frame are prepared.
	v.stepSelectionScroll(v.clock)

	canvas.Fill(area, v.pal.terminal)
	v.paintGrid(canvas, v.layout)
	v.paintScrollbar(canvas)
}

// paintGrid draws the character grid: for each row its background spans and one fixed-pitch
// label, then the cursor. Rows are prepared once per change of their content; painting a
// screen that did not change builds nothing.
func (v *View) paintGrid(canvas *gfx.Canvas, layout geometry) {
	pal := &v.pal
	focused := canvas.Focused() == v.cfg.HitID
	cols, rows := v.screen.Size()
	cellWidth, cellHeight := v.cellW, v.cellH
	cursor := v.screen.Cursor()
	composing := v.preedit.Composing

	// The cursor blinks while the terminal has the keyboard and something is happening; it
	// is solid from the moment it moves or the terminal is entered.
	blinkOn := true
	if cursor.Visible && focused && !composing && !cursor.Steady {
		blinkOn = v.blink.on(canvas, cursor.X, cursor.Y)
	} else {
		v.blink.rest(cursor.X, cursor.Y)
	}
	// A block cursor is an inverted cell prepared by the row cache, so it follows the
	// cursor column rather than being a rectangle painted over the text.
	block := cursor.Visible && cursor.Style == term.CursorBlock && focused && !composing && blinkOn
	// The input method draws its composition over the cells from the cursor on, where it
	// replaces whatever the program put there. A program that draws its own cursor (a prompt
	// with placeholder text) hides the real one, so the cells are covered whether the cursor
	// shows or not.
	var covered cellSpan
	if composing && cursor.Y < rows {
		covered = cellSpan{from: cursor.X, to: cursor.X + displayCells(v.preedit.Value)}
	}
	style := gfx.TextStyle{Size: fontSize, Color: pal.termFG, Mono: true, MonoFace: v.face}
	labelWidth := float32(math.Ceil(float64(float32(cols)*cellWidth))) + 1

	// The edge scroll of a selection drag steps on a clock, not on pointer events, so the
	// frames that carry it are asked for here for as long as the drag is at an edge.
	if v.selection.dragging && v.selection.edge.direction != 0 {
		canvas.RequestFrameIn(selectionScrollInterval)
	}
	canvas.Clip(layout.area)
	v.cache.begin()
	// The first pass lays down every row's backgrounds, so no row's ground covers the text
	// of the row above it that reaches into its cells.
	for row := 0; row < rows; row++ {
		column := -1
		if block && row == cursor.Y {
			column = cursor.X
		}
		entry := v.cache.row(v.screen.Row(row), cols, column, coveredOn(covered, row == cursor.Y), pal)
		y := layout.top + float32(row)*cellHeight
		for _, span := range entry.spans {
			from := snap(layout.left + float32(span.from)*cellWidth)
			to := snap(layout.left + float32(span.to)*cellWidth)
			canvas.Fill(gfx.Rect{X: from, Y: y, Width: to - from, Height: cellHeight}, span.color)
		}
	}
	// The second pass paints the selection over the backgrounds and each row's text over
	// the selection.
	for row := 0; row < rows; row++ {
		column := -1
		if block && row == cursor.Y {
			column = cursor.X
		}
		line := v.screen.Row(row)
		entry := v.cache.row(line, cols, column, coveredOn(covered, row == cursor.Y), pal)
		y := layout.top + float32(row)*cellHeight
		if from, to, selected := v.selection.span(v.screen.LineNumber(row), line, cols); selected {
			left := snap(layout.left + float32(from)*cellWidth)
			right := snap(layout.left + float32(to)*cellWidth)
			canvas.Fill(gfx.Rect{X: left, Y: y, Width: right - left, Height: cellHeight}, pal.selection)
		}
		if len(entry.runs) > 0 {
			last := entry.runs[len(entry.runs)-1]
			rowCols := min(int(last.Column+last.Cells)+1, cols)
			rowWidth := min(float32(math.Ceil(float64(float32(rowCols)*cellWidth)))+1, labelWidth)
			canvas.LabelRuns(entry.text, gfx.Rect{X: layout.left, Y: y, Width: rowWidth, Height: cellHeight}, style, cellWidth, entry.runs)
		}
	}
	v.cache.end(rows)

	if cursor.Visible && cursor.Y < rows {
		cursorColor := pal.cursor
		x := layout.left + float32(cursor.X)*cellWidth
		y := layout.top + float32(cursor.Y)*cellHeight
		switch {
		case !blinkOn:
			// The dark half of a blink.
		case composing:
			// The input method draws over these cells, which the rows left empty.
		case cursor.Style == term.CursorUnderline:
			canvas.Fill(gfx.Rect{X: x, Y: y + cellHeight - cursorUnderlineHeight, Width: cellWidth, Height: cursorUnderlineHeight}, cursorColor)
		case cursor.Style == term.CursorBar:
			canvas.Fill(gfx.Rect{X: x, Y: y, Width: cursorBarWidth, Height: cellHeight}, cursorColor)
		case !focused:
			// A block cursor outlines its cell while the terminal does not have the keyboard.
			canvas.Fill(gfx.Rect{X: x, Y: y, Width: cellWidth, Height: 1}, cursorColor)
			canvas.Fill(gfx.Rect{X: x, Y: y + cellHeight - 1, Width: cellWidth, Height: 1}, cursorColor)
			canvas.Fill(gfx.Rect{X: x, Y: y, Width: 1, Height: cellHeight}, cursorColor)
			canvas.Fill(gfx.Rect{X: x + cellWidth - 1, Y: y, Width: 1, Height: cellHeight}, cursorColor)
		}
	}
	if covered != (cellSpan{}) {
		// The composition itself is drawn by the input method; the terminal only clears the
		// cells it will sit on.
		x := layout.left + float32(covered.from)*cellWidth
		y := layout.top + float32(cursor.Y)*cellHeight
		canvas.Fill(gfx.Rect{X: x, Y: y, Width: float32(covered.to-covered.from) * cellWidth, Height: cellHeight}, pal.terminal)
	}
	canvas.Unclip()

	// The hit comes after the grid and before the scrollbar, whose track is declared later
	// and so wins the pointer over the strip it covers.
	canvas.HitWithOptions(v.cfg.HitID, layout.area, v.cfg.Messages.Label, gfx.HitOptions{Role: gfx.RoleTerminal})
}

// coveredOn is covered when it is on the row being prepared, else nothing.
func coveredOn(covered cellSpan, onRow bool) cellSpan {
	if onRow {
		return covered
	}
	return cellSpan{}
}
