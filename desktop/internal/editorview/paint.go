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
	font := v.font
	cellW, cellH := canvas.MonoCellSize(font.Size, font.Face)
	if cellW <= 0 || cellH <= 0 || area.Width <= 0 || area.Height <= 0 {
		return
	}
	// A line is at least a point high, however small the spacing is, so the rows the scroll is
	// divided into never have no height.
	lineH := max(float32(math.Round(float64(cellH*font.LineSpacing))), 1)
	// The scroll is in pixels, so it means a different place once the cell's size changes, as it
	// does when the font does. The paint keeps the reader's place: the column at the left edge of
	// the view stays there (here), and so does the row at the top (setWrapCols below, which also
	// lays a wrapped text out again for the new width of a cell). Before the first paint nothing
	// has been measured, so nothing moves.
	wasCellW, wasLineH := v.cellW, v.lineH
	if wasCellW > 0 && wasCellW != cellW {
		v.scrollX = v.scrollX / wasCellW * cellW
	}
	if wasLineH <= 0 {
		wasLineH = lineH
	}
	v.cellW, v.cellH, v.lineH = cellW, cellH, lineH
	v.applyLook(look)
	lines := v.text.LineCount()
	digits := v.gutterDigits(lines)
	// The gutter is the numbers with their padding, then the icon column, then the fold arrows.
	numbersEnd := float32(digits)*cellW + 2*gutterPad
	gutter := numbersEnd + v.lineIconColumn() + v.foldColumn()
	v.iconX = area.X + numbersEnd + lineIconInset
	v.fold.x = area.X + numbersEnd + v.lineIconColumn()
	v.fold.boxes = v.fold.boxes[:0]
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
	v.setWrapCols(cols, wasLineH)
	v.revealHiddenCaret()
	if v.reveal {
		v.revealCaret()
		v.reveal = false
	}
	v.applyCenter()
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
	v.paintHighlights(canvas, v.textRight, firstLine, lastLine)
	canvas.Clip(textArea)
	annotation := 0
	top := area.Y + float32(firstRow-firstSub)*v.lineH - v.scroll
	for line := firstLine; line <= lastLine; line++ {
		l := v.ref(line)
		wraps := v.rowsOf(l)
		if len(wraps) == 0 {
			// A folded line: no rows, no number.
			continue
		}
		if top+v.lineH > area.Y {
			v.numbers = append(v.numbers, gutterNumber{line: line, y: top})
		}
		if line == caretLine && selStart == selEnd {
			canvas.Fill(gfx.Rect{X: textArea.X, Y: top, Width: textArea.Width, Height: float32(len(wraps)) * v.lineH}, look.CurrentLine)
		}
		selFrom, selTo := v.selectionCells(l, selStart, selEnd)
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
			end := l.size
			if k+1 < len(wraps) {
				end = wraps[k+1].at
			}
			p := v.part(l, row, end, from, to)
			v.paintRow(canvas, p.text, p.base, p.row, from, to, shift, y)
			v.paintMarkers(canvas, line, from, to, shift, y)
			if k == len(wraps)-1 && v.paintFoldBox(canvas, l, row, y, look) == 0 {
				v.paintAnnotation(canvas, l, row, y, look, &annotation)
			}
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
	v.paintGutterDecorations(canvas, area, look, firstLine, lastLine)
	v.paintLineIcons(canvas, area, look, firstLine, lastLine)
	v.paintFoldArrows(canvas, area, look, firstLine, lastLine)
	style := gfx.TextStyle{Size: font.Size, Color: look.Subtle, Mono: true, MonoFace: font.Face}
	right := area.X + numbersEnd - gutterPad
	for _, number := range v.numbers {
		label := v.lineLabel(number.line)
		n := len(label)
		if n == 0 {
			continue
		}
		style.Color = look.Subtle
		if number.line == caretLine {
			style.Color = look.Foreground
		}
		run := [1]gfx.TextRun{{Bytes: int32(n), Cells: int32(n), Color: style.Color}}
		rect := gfx.Rect{X: right - float32(n)*cellW, Y: number.y + (v.lineH-cellH)/2, Width: float32(n)*cellW + 1, Height: cellH}
		canvas.LabelRuns(label, rect, style, cellW, run[:])
	}
	canvas.Unclip()
	v.paintMinimap(canvas, look, selStart, selEnd)
	v.paintScrollbars(canvas, look)
	v.paintToggle(canvas, look)
}

// joinedLines is how many copied lines the view keeps for a text, joinedBytes the longest line
// it keeps and joinedLimit how many bytes of them it keeps in all: a screen holds a line or two
// that a leaf boundary cuts. A longer line is copied again each time it is read.
const (
	joinedLines = 256
	joinedBytes = 64 << 10
	joinedLimit = 1 << 20
)

// lineIn returns line of the text, which runs from byte start to byte end of it. A line in one
// leaf of the rope is part of the rope's memory; a line across leaves is copied, and the copy
// of a line no longer than joinedBytes is kept until the text changes, so a frame that shows
// the line again copies nothing. The view reads a longer line a part at a time instead (see
// longline.go).
func (v *View) lineIn(line, start, end int) string {
	if v.joinedRevision != v.revision {
		clear(v.joined)
		v.joinedRevision, v.joinedSize = v.revision, 0
	}
	if text, ok := v.joined[line]; ok {
		return text
	}
	text, copied := v.text.Substring(start, end)
	if copied && len(text) <= joinedBytes {
		if v.joined == nil {
			v.joined = make(map[int]string)
		} else if len(v.joined) >= joinedLines || v.joinedSize+len(text) > joinedLimit {
			clear(v.joined)
			v.joinedSize = 0
		}
		v.joined[line] = text
		v.joinedSize += len(text)
	}
	return text
}

// numberStep and numberSpan place the window of line numbers the gutter keeps as text: it
// starts at a multiple of numberStep and holds numberSpan numbers, as Viva's code editor keeps
// them, so a screen inside it formats nothing and scrolling moves it once in numberStep lines.
const (
	numberStep = 128
	numberSpan = 3 * numberStep
)

// lineNumbers is the text of the line numbers in a window of lines, one after the other.
type lineNumbers struct {
	// from is the first line of the window, counted from 0.
	from int
	// text is the numbers of the window's lines, counted from 1, and ends where each ends in
	// text; buf is where text is formatted.
	text string
	ends []int32
	buf  []byte
}

// number is the number of line, counted from 0, as the gutter shows it: part of the window's
// text, moving the window to line when it does not hold it.
func (n *lineNumbers) number(line int) string {
	if line < n.from || line >= n.from+len(n.ends) {
		n.from = line - line%numberStep
		n.buf, n.ends = n.buf[:0], n.ends[:0]
		for k := range numberSpan {
			n.buf = strconv.AppendInt(n.buf, int64(n.from+k+1), 10)
			n.ends = append(n.ends, int32(len(n.buf)))
		}
		n.text = string(n.buf)
	}
	k := line - n.from
	start := int32(0)
	if k > 0 {
		start = n.ends[k-1]
	}
	return n.text[start:n.ends[k]]
}

// decimalDigits is how many digits n, at least 0, has in decimal.
func decimalDigits(n int) int {
	digits := 1
	for ; n >= 10; n /= 10 {
		digits++
	}
	return digits
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

// selectionCells is the columns of l that the selection from selStart to selEnd covers; a line
// the selection runs past also gets its line break selected, one cell wide. Both are 0 when the
// selection misses the line.
func (v *View) selectionCells(l lineRef, selStart, selEnd int) (int, int) {
	start := l.start
	end := start + l.size
	if selStart == selEnd || selEnd < start || selStart > end {
		return 0, 0
	}
	from := v.cellsAt(l, max(selStart-start, 0))
	to := v.cellsAt(l, min(selEnd-start, l.size))
	if selEnd > end {
		to++
	}
	return from, to
}

// paintRow draws the columns from to to of a row of a line in its tokens' colors, which v.tokens
// holds; text is the line's bytes from byte base, as far as the paint needs them, the row starts
// at row, at or after base, and it is drawn shift columns to the left.
// Every character that is not ASCII is a run of its own at its own cell, so a wide or fallback
// glyph never moves the text after it off its column.
//
// A label shows part of the line as it is, so drawing a row copies nothing: a tab or another
// control character is a blank stretch of cells between two labels instead of spaces inside
// one, a character of no width ends the label before it, and a byte that is not UTF-8 is a
// label of its own that shows U+FFFD. Indentation therefore only moves where a row's label
// starts.
//
// Only the columns the view shows are drawn, starting at the first of them, the way Viva's own
// code editor draws a row, so a frame of the single line of a minified JSON file costs the
// width of the view, not the length of the line, and of such a line text is only those columns
// (see part in longline.go). The macOS renderer splits a label wider than
// a texture across textures, but the Windows one refuses a label texture wider than 16384
// pixels, so a view wider than labelWidth draws its columns as several labels side by side,
// each starting where the one before it ended.
func (v *View) paintRow(canvas *gfx.Canvas, text string, base int, row wrapRow, from, to, shift int, y float32) {
	stop := base + len(text)
	if row.at >= stop {
		return
	}
	limit := v.labelCells()
	v.runs = v.runs[:0]
	defaultStyle := v.theme.Default()
	textStyle := gfx.TextStyle{Size: v.font.Size, Color: uiColor(defaultStyle.Foreground), Mono: true, MonoFace: v.font.Face}
	ligatures := v.font.Ligatures
	// token is the last token that starts at or before the row.
	token := max(sort.Search(len(v.tokens), func(i int) bool { return int(v.tokens[i].Start) > row.at })-1, 0)
	cells := row.cells
	run := -1
	runASCII := false
	// label is the first column of the label being gathered, or -1 while there is none, and
	// labelEnd the column after its last character; labelAt and labelTo are the bytes of the
	// line it shows.
	label, labelEnd, labelAt, labelTo := -1, 0, base, base
	for i := row.at; i < stop; {
		at := i
		r, size := utf8.DecodeRuneInString(text[i-base:])
		i += size
		width := runeCells(r, cells)
		if width == 0 {
			v.paintLabel(canvas, text[labelAt-base:labelTo-base], label, labelEnd, shift, y, textStyle)
			label = -1
			continue
		}
		if cells+width <= from {
			cells += width
			continue
		}
		if cells >= to {
			break
		}
		if r == '\t' || r < 0x20 {
			v.paintLabel(canvas, text[labelAt-base:labelTo-base], label, labelEnd, shift, y, textStyle)
			label = -1
			cells += width
			continue
		}
		invalid := r == utf8.RuneError && size == 1
		if label < 0 || invalid || cells+width-label > limit {
			v.paintLabel(canvas, text[labelAt-base:labelTo-base], label, labelEnd, shift, y, textStyle)
			label, labelAt, labelTo, run = cells, at, at, -1
		}
		for token+1 < len(v.tokens) && int(v.tokens[token+1].Start) <= at {
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
		if ascii && runASCII && run >= 0 &&
			v.runs[run].Color == color && v.runs[run].Weight == weight && v.runs[run].Italic == italic {
			v.runs[run].Bytes += int32(size)
			v.runs[run].Cells += int32(width)
			// Only a run of ASCII reaches this merge, and one of two cells or more is what the
			// renderer shapes as one line, so the font's ligatures show. A run of a single
			// character, or of any other, is never asked to.
			v.runs[run].Ligatures = ligatures && v.runs[run].Cells >= 2
		} else {
			bytes := size
			if invalid {
				bytes = len(replacementChar)
			}
			v.runs = append(v.runs, gfx.TextRun{
				Column: int32(cells - label), Bytes: int32(bytes), Cells: int32(width),
				Color: color, Weight: weight, Italic: italic, Underline: style.Font&syntax.Underline != 0,
				Strike: style.Font&syntax.Strikethrough != 0,
			})
			run, runASCII = len(v.runs)-1, ascii
		}
		cells += width
		labelEnd, labelTo = cells, i
		if invalid {
			v.paintLabel(canvas, replacementChar, label, labelEnd, shift, y, textStyle)
			label = -1
		}
	}
	v.paintLabel(canvas, text[labelAt-base:labelTo-base], label, labelEnd, shift, y, textStyle)
}

// replacementChar is what a byte that is not UTF-8 shows, as range over a string reads it.
const replacementChar = "\uFFFD"

// markerThickness is how tall an underline is, in pixels. Two is the thinnest line
// that survives a device pixel ratio above one.
const markerThickness = 2

// paintMarkers underlines the diagnostics that fall inside one wrapped row.
//
// A marker is laid out on the cell grid like the text above it, so the underline
// stays under the characters it belongs to when the row is scrolled or wrapped.
func (v *View) paintMarkers(canvas *gfx.Canvas, line, from, to, shift int, y float32) {
	if len(v.markers) == 0 {
		return
	}
	for _, marker := range v.markers[line] {
		start, end := max(marker.Start, from), min(marker.End, to)
		if end <= start {
			continue
		}
		left := v.textLeft + float32(start-shift)*v.cellW - v.scrollX
		canvas.Fill(gfx.Rect{
			X:      left,
			Y:      y + v.lineH - markerThickness,
			Width:  float32(end-start) * v.cellW,
			Height: markerThickness,
		}, markerColor(marker.Severity))
	}
}

// markerColor is the colour of one severity. These are the editor's own diagnostic
// colours rather than theme entries: a theme may restyle syntax, but a problem has
// to stay recognisable in every theme.
func markerColor(severity MarkerSeverity) gfx.Color {
	switch severity {
	case MarkerError:
		return gfx.RGB24(0xD13B3B)
	case MarkerWarning:
		return gfx.RGB24(0xC07A00)
	default:
		return gfx.RGB24(0x3B76D1)
	}
}

// paintLabel draws the runs gathered for a row from column start to column end as one label of
// value, shift columns to the left, and empties them for the next label.
func (v *View) paintLabel(canvas *gfx.Canvas, value string, start, end, shift int, y float32, style gfx.TextStyle) {
	if len(v.runs) == 0 {
		return
	}
	width := float32(math.Ceil(float64(float32(end-start)*v.cellW))) + 1
	rect := gfx.Rect{X: v.textLeft + float32(start-shift)*v.cellW - v.scrollX, Y: y + (v.lineH-v.cellH)/2, Width: width, Height: v.cellH}
	canvas.LabelRuns(value, rect, style, v.cellW, v.runs)
	v.runs = v.runs[:0]
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
	l, rows, k := v.caretPlace()
	cells := v.cellsAt(l, v.caret-l.start) - rows[k].cells
	return v.textLeft + float32(cells)*v.cellW - v.scrollX, v.area.Y + float32(v.lineRow(l.line)+k)*v.lineH - v.scroll
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
	l, _, k := v.caretPlace()
	top := float32(v.lineRow(l.line)+k) * v.lineH
	if top < v.scroll {
		v.scroll = top
	} else if bottom := top + v.lineH; bottom > v.scroll+v.rowsHeight() {
		v.scroll = bottom - v.rowsHeight()
	}
	if v.wrapping() {
		return
	}
	width := v.textRight - v.textLeft
	x := float32(v.cellsAt(l, v.caret-l.start)) * v.cellW
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
