package editorview

import (
	"math"
	"sort"
	"strconv"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/gfx"
)

const (
	// gutterPad is the room on each side of the line numbers, and textPad the room between
	// the gutter and the text.
	gutterPad = float32(12)
	textPad   = float32(8)
	// barWidth is the thickness of a scrollbar's thumb, and barMin its least length. See
	// scrollbar.go.
	barWidth = float32(6)
	barMin   = float32(24)
	// prepareMargin is how many lines past the screen the highlighter colors ahead.
	prepareMargin = 50
	// labelWidth is the most points one label of a line spans. Even at a display scale of
	// four its texture stays well inside the 16384 pixels the Windows renderer holds.
	labelWidth = float32(2048)
)

// Paint draws the view into area: the line numbers, the band of the caret's line, the
// selection, the colored text, the caret, the minimap and the scrollbars. It also declares the
// view's hits, so the view takes the pointer and the keyboard where it was painted.
func (v *View) Paint(canvas *gfx.Canvas, area gfx.Rect, look Look) {
	v.clock = canvas.Now()
	cellW, cellH := canvas.MonoCellSize(fontSize, 0)
	if cellW <= 0 || cellH <= 0 || area.Width <= 0 || area.Height <= 0 {
		return
	}
	v.cellW, v.cellH = cellW, cellH
	v.lineH = float32(math.Round(float64(cellH * lineSpacing)))
	v.applyLook(look)
	lines := v.text.LineCount()
	digits := max(len(strconv.Itoa(lines)), 2)
	gutter := float32(digits)*cellW + 2*gutterPad
	v.area = area
	v.textLeft = area.X + gutter + textPad
	v.layoutParts(gutter)
	v.painted = true
	v.focused = canvas.Focused() == v.cfg.HitID
	cols := 0
	if v.wrap {
		// A cell is kept free at the right edge for the caret after a full row.
		cols = max(int((v.textRight-v.textLeft-cellW)/cellW), 1)
	}
	v.setWrapCols(cols)
	if v.reveal {
		v.revealCaret()
		v.reveal = false
	}
	v.clampScroll()

	canvas.Fill(area, look.Background)
	canvas.HitWithOptions(v.cfg.HitID, area, v.cfg.Label, gfx.HitOptions{Role: gfx.RoleTerminal, Cursor: gfx.PointerCursorText})

	rows := v.rowCount()
	firstRow := min(int(v.scroll/v.lineH), rows-1)
	lastRow := min(int((v.scroll+area.Height)/v.lineH), rows-1)
	firstLine, firstSub := v.rowLine(firstRow)
	lastLine, _ := v.rowLine(lastRow)
	// The highlighter keeps the tokens of one range, so it is the lines the minimap shows too.
	prepareFirst, prepareLast := max(firstLine-prepareMargin, 0), min(lastLine+prepareMargin, lines-1)
	if _, mapFirst, mapLast, ok := v.minimapRange(); ok {
		mapFirstLine, _ := v.rowLine(mapFirst)
		mapLastLine, _ := v.rowLine(mapLast)
		prepareFirst, prepareLast = min(prepareFirst, mapFirstLine), max(prepareLast, mapLastLine)
	}
	v.hl.Prepare(prepareFirst, prepareLast)

	selStart, selEnd := v.Selection()
	caretLine := v.text.LineOf(v.caret)
	textArea := gfx.Rect{X: area.X + gutter, Y: area.Y, Width: v.textRight - area.X - gutter, Height: area.Height}
	bottom := area.Y + area.Height
	v.numbers = v.numbers[:0]
	canvas.Clip(textArea)
	top := area.Y + float32(firstRow-firstSub)*v.lineH - v.scroll
	for line := firstLine; line <= lastLine; line++ {
		text := v.text.Line(line)
		wraps := v.rowsOf(line, text)
		if top+v.lineH > area.Y {
			v.numbers = append(v.numbers, gutterNumber{line: line, y: top})
		}
		if line == caretLine && selStart == selEnd {
			canvas.Fill(gfx.Rect{X: textArea.X, Y: top, Width: textArea.Width, Height: float32(len(wraps)) * v.lineH}, look.CurrentLine)
		}
		selFrom, selTo := v.selectionCells(line, text, selStart, selEnd)
		v.tokens = v.hl.Line(v.tokens[:0], line)
		for k, row := range wraps {
			y := top + float32(k)*v.lineH
			if y+v.lineH <= area.Y {
				continue
			}
			if y >= bottom {
				break
			}
			// A wrapped row shows its own columns, moved to the left edge; an unwrapped line
			// shows the columns scrolled into view.
			from, to, shift := row.cells, math.MaxInt, row.cells
			if k+1 < len(wraps) {
				to = wraps[k+1].cells
			}
			if !v.wrapping() {
				from, to = v.visibleCells()
			}
			lo, hi := selFrom, selTo
			if v.wrapping() {
				lo, hi = max(lo, row.cells), min(hi, to)
			}
			if hi > lo {
				left := v.textLeft + float32(lo-shift)*v.cellW - v.scrollX
				canvas.Fill(gfx.Rect{X: left, Y: y, Width: float32(hi-lo) * v.cellW, Height: v.lineH}, look.Selection)
			}
			v.paintRow(canvas, text, row, from, to, shift, y)
		}
		top += float32(len(wraps)) * v.lineH
	}
	if v.focused && !v.preedit.Composing && v.blinkOn(canvas) {
		x, y := v.caretPoint()
		canvas.Fill(gfx.Rect{X: float32(math.Round(float64(x))), Y: y, Width: 2, Height: v.lineH}, look.Caret)
	}
	canvas.Unclip()

	// The numbers go over the gutter last, so text scrolled sideways never shows under them, and
	// inside a clip of their own, so a number scrolled half out of the view never shows over what
	// is above or below it. Each is a line on the cell grid with its right edge on the gutter's,
	// as the text is, so their digits stay in columns: a label aligned by its width would be
	// measured at the font's own advance, not the grid's, and drift off it.
	canvas.Clip(gfx.Rect{X: area.X, Y: area.Y, Width: gutter, Height: area.Height})
	style := gfx.TextStyle{Size: fontSize, Color: look.Subtle, Mono: true}
	right := area.X + gutter - gutterPad
	for _, number := range v.numbers {
		v.display = strconv.AppendInt(v.display[:0], int64(number.line+1), 10)
		n := len(v.display)
		style.Color = look.Subtle
		if number.line == caretLine {
			style.Color = look.Foreground
		}
		run := [1]gfx.TextRun{{Bytes: int32(n), Cells: int32(n), Color: style.Color}}
		rect := gfx.Rect{X: right - float32(n)*cellW, Y: number.y + (v.lineH-cellH)/2, Width: float32(n)*cellW + 1, Height: cellH}
		canvas.LabelRuns(string(v.display), rect, style, cellW, run[:])
	}
	v.display = v.display[:0]
	canvas.Unclip()
	v.paintMinimap(canvas, look, selStart, selEnd)
	v.paintScrollbars(canvas, look)
	v.paintToggle(canvas, look)
}

// gutterNumber is a line number to paint: the line, and the top of its first row.
type gutterNumber struct {
	line int
	y    float32
}

// applyLook rebuilds the syntax theme when the light or dark look or the plain text color
// changed.
func (v *View) applyLook(look Look) {
	if v.theme != nil && v.themeDark == look.Dark && v.themeFG == look.Foreground {
		return
	}
	v.themeDark, v.themeFG = look.Dark, look.Foreground
	v.theme = syntax.BuildTheme(syntax.ThemeOptions{Dark: look.Dark, Scheme: syntax.SchemeLithe, Foreground: hexColor(look.Foreground)}, syntax.DefaultPalette())
}

// hexColor writes c as "#RRGGBB".
func hexColor(c gfx.Color) string {
	channel := func(f float32) uint32 { return uint32(math.Round(float64(min(max(f, 0), 1) * 255))) }
	value := channel(c.Red)<<16 | channel(c.Green)<<8 | channel(c.Blue)
	s := strconv.FormatUint(uint64(value), 16)
	for len(s) < 6 {
		s = "0" + s
	}
	return "#" + s
}

// uiColor turns a theme color into a canvas color.
func uiColor(c syntax.Color) gfx.Color {
	return gfx.Color{Red: float32(c>>16&0xff) / 255, Green: float32(c>>8&0xff) / 255, Blue: float32(c&0xff) / 255, Alpha: 1}
}

// selectionCells is the columns of line, whose text is text, that the selection from selStart
// to selEnd covers; a line the selection runs past also gets its line break selected, one cell
// wide. Both are 0 when the selection misses the line.
func (v *View) selectionCells(line int, text string, selStart, selEnd int) (int, int) {
	start := v.text.LineStart(line)
	end := start + len(text)
	if selStart == selEnd || selEnd < start || selStart > end {
		return 0, 0
	}
	from := cellsOf(text, max(selStart-start, 0))
	to := cellsOf(text, min(selEnd-start, len(text)))
	if selEnd > end {
		to++
	}
	return from, to
}

// paintRow draws the columns from to to of a row of a line, whose text is text, in its tokens'
// colors, which v.tokens holds; the row starts at row and is drawn shift columns to the left.
// Tabs become spaces to the next tab stop, and every character that is not ASCII is a run of
// its own at its own cell, so a wide or fallback glyph never moves the text after it off its
// column.
//
// Only the columns the view shows are drawn, as one label that starts at the first of them,
// the way Viva's own code editor draws a row, so a frame of the single line of a minified
// JSON file costs the width of the view, not the length of the line. The macOS renderer
// splits a label wider than a texture across textures, but the Windows one refuses a label
// texture wider than 16384 pixels, so a view wider than labelWidth draws its columns as
// several labels side by side, each starting where the one before it ended.
func (v *View) paintRow(canvas *gfx.Canvas, text string, row wrapRow, from, to, shift int, y float32) {
	if row.at >= len(text) {
		return
	}
	limit := v.labelCells()
	v.runs = v.runs[:0]
	v.display = v.display[:0]
	defaultStyle := v.theme.Default()
	textStyle := gfx.TextStyle{Size: fontSize, Color: uiColor(defaultStyle.Foreground), Mono: true}
	// token is the last token that starts at or before the row.
	token := max(sort.Search(len(v.tokens), func(i int) bool { return int(v.tokens[i].Start) > row.at })-1, 0)
	cells := row.cells
	run := -1
	runASCII := false
	// label is the first column of the label being gathered, and labelEnd the column after its
	// last character.
	label, labelEnd := -1, 0
	for i, r := range text[row.at:] {
		i += row.at
		width := runeCells(r, cells)
		if width == 0 {
			continue
		}
		if cells+width <= from {
			cells += width
			continue
		}
		if cells >= to {
			break
		}
		// A tab that starts before the first visible column shows only its spaces from there,
		// so the label still starts at that column.
		if r == '\t' && cells < from {
			width -= from - cells
			cells = from
		}
		if label < 0 || cells+width-label > limit {
			v.paintLabel(canvas, label, labelEnd, shift, y, textStyle)
			label, run = cells, -1
		}
		for token+1 < len(v.tokens) && int(v.tokens[token+1].Start) <= i {
			token++
		}
		style := defaultStyle
		if token < len(v.tokens) {
			style = v.theme.Style(v.tokens[token].Name)
		}
		color := uiColor(style.Foreground)
		weight := float32(0)
		if style.Font&syntax.Bold != 0 {
			weight = gfx.WeightBold
		}
		italic := style.Font&syntax.Italic != 0
		ascii := r < 0x80
		if r == '\t' || r < 0x20 {
			r = ' '
		}
		column := cells - label
		if ascii && runASCII && run >= 0 && int(v.runs[run].Column+v.runs[run].Cells) == column &&
			v.runs[run].Color == color && v.runs[run].Weight == weight && v.runs[run].Italic == italic {
			for range width {
				v.display = append(v.display, byte(r))
			}
			v.runs[run].Bytes += int32(width)
			v.runs[run].Cells += int32(width)
			cells += width
			labelEnd = cells
			continue
		}
		before := len(v.display)
		if ascii {
			for range width {
				v.display = append(v.display, byte(r))
			}
		} else {
			v.display = utf8.AppendRune(v.display, r)
		}
		v.runs = append(v.runs, gfx.TextRun{
			Column: int32(column), Bytes: int32(len(v.display) - before), Cells: int32(width),
			Color: color, Weight: weight, Italic: italic, Underline: style.Font&syntax.Underline != 0,
			Strike: style.Font&syntax.Strikethrough != 0,
		})
		run, runASCII = len(v.runs)-1, ascii
		cells += width
		labelEnd = cells
	}
	v.paintLabel(canvas, label, labelEnd, shift, y, textStyle)
}

// paintLabel draws the runs gathered for a row from column start to column end as one label,
// shift columns to the left, and empties them for the next label.
func (v *View) paintLabel(canvas *gfx.Canvas, start, end, shift int, y float32, style gfx.TextStyle) {
	if len(v.runs) == 0 {
		return
	}
	width := float32(math.Ceil(float64(float32(end-start)*v.cellW))) + 1
	rect := gfx.Rect{X: v.textLeft + float32(start-shift)*v.cellW - v.scrollX, Y: y + (v.lineH-v.cellH)/2, Width: width, Height: v.cellH}
	canvas.LabelRuns(string(v.display), rect, style, v.cellW, v.runs)
	v.runs = v.runs[:0]
	v.display = v.display[:0]
}

// labelCells is how many columns one label of a line holds at most: as many as fit in
// labelWidth.
func (v *View) labelCells() int {
	return max(int(labelWidth/v.cellW), 1)
}

// visibleCells is the range of columns, from the first to the one after the last, that the
// view shows of a line at its sideways scroll. It starts textPad early, because the text
// scrolled left shows in the pad between the gutter and textLeft.
func (v *View) visibleCells() (int, int) {
	left := v.scrollX - textPad
	right := v.scrollX + v.textRight - v.textLeft
	return max(int(left/v.cellW), 0), max(int(math.Ceil(float64(right/v.cellW))), 0)
}

// caretPoint is the top left corner of the caret.
func (v *View) caretPoint() (float32, float32) {
	line, text, rows, k := v.caretPlace()
	cells := cellsOf(text, v.caret-v.text.LineStart(line)) - rows[k].cells
	return v.textLeft + float32(cells)*v.cellW - v.scrollX, v.area.Y + float32(v.lineRow(line)+k)*v.lineH - v.scroll
}

// blinkOn says whether the caret shows in this frame, and asks for the frame that turns it
// over: it is solid for a period after it moved and then blinks.
func (v *View) blinkOn(canvas *gfx.Canvas) bool {
	elapsed := v.clock - v.blinkFrom
	if elapsed < 0 {
		v.blinkFrom, elapsed = v.clock, 0
	}
	phase := elapsed / blinkPeriod
	canvas.RequestFrameIn(blinkPeriod - elapsed%blinkPeriod)
	return phase%2 == 0
}

// revealCaret scrolls the least that brings the caret's row and column into view.
func (v *View) revealCaret() {
	line, text, _, k := v.caretPlace()
	top := float32(v.lineRow(line)+k) * v.lineH
	if top < v.scroll {
		v.scroll = top
	} else if bottom := top + v.lineH; bottom > v.scroll+v.rowsHeight() {
		v.scroll = bottom - v.rowsHeight()
	}
	if v.wrapping() {
		return
	}
	width := v.textRight - v.textLeft
	x := float32(cellsOf(text, v.caret-v.text.LineStart(line))) * v.cellW
	margin := 4 * v.cellW
	if x < v.scrollX {
		v.scrollX = max(x-margin, 0)
	} else if x+v.cellW > v.scrollX+width {
		v.scrollX = x + v.cellW + margin - width
	}
}

// clampScroll keeps the scroll in range: down until the last row is at the bottom, and sideways
// as far as its widest line, and not at all while the text wraps.
func (v *View) clampScroll() {
	v.scroll = min(max(v.scroll, 0), v.maxScroll())
	v.scrollX = min(max(v.scrollX, 0), v.maxScrollX())
}
