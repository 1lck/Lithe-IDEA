package editorview

import (
	"math"
	"strconv"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/ui"
)

const (
	// gutterPad is the room on each side of the line numbers, and textPad the room between
	// the gutter and the text.
	gutterPad = float32(12)
	textPad   = float32(8)
	// barWidth is the thickness of a scrollbar's thumb, and barMin its least length.
	barWidth = float32(6)
	barMin   = float32(24)
	// prepareMargin is how many lines past the screen the highlighter colors ahead.
	prepareMargin = 50
)

// Paint draws the view into area: the line numbers, the band of the caret's line, the
// selection, the colored text, the caret and the scrollbars. It also declares the view's hit,
// so the view takes the pointer and the keyboard where it was painted.
func (v *View) Paint(canvas *ui.Canvas, area ui.Rect, look Look) {
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
	v.painted = true
	v.focused = canvas.Focused() == v.cfg.HitID
	if v.reveal {
		v.revealCaret()
		v.reveal = false
	}
	v.clampScroll()

	canvas.Fill(area, look.Background)
	canvas.HitWithOptions(v.cfg.HitID, area, v.cfg.Label, ui.HitOptions{Role: ui.RoleTerminal, Cursor: ui.PointerCursorText})

	first := min(int(v.scroll/v.lineH), lines-1)
	last := min(int((v.scroll+area.Height)/v.lineH), lines-1)
	v.hl.Prepare(max(first-prepareMargin, 0), min(last+prepareMargin, lines-1))

	selStart, selEnd := v.Selection()
	caretLine := v.text.LineOf(v.caret)
	textArea := ui.Rect{X: area.X + gutter, Y: area.Y, Width: area.Width - gutter, Height: area.Height}
	canvas.Clip(textArea)
	for line := first; line <= last; line++ {
		y := area.Y + float32(line)*v.lineH - v.scroll
		row := ui.Rect{X: textArea.X, Y: y, Width: textArea.Width, Height: v.lineH}
		if line == caretLine && selStart == selEnd {
			canvas.Fill(row, look.CurrentLine)
		}
		text := v.text.Line(line)
		start := v.text.LineStart(line)
		if selStart != selEnd {
			v.paintSelection(canvas, line, text, start, y, selStart, selEnd, look)
		}
		v.paintLine(canvas, line, text, y)
	}
	if v.focused && !v.preedit.Composing && v.blinkOn(canvas) {
		x, y := v.caretPoint()
		canvas.Fill(ui.Rect{X: float32(math.Round(float64(x))), Y: y, Width: 2, Height: v.lineH}, look.Caret)
	}
	canvas.Unclip()

	// The numbers go over the gutter last, so text scrolled sideways never shows under them.
	style := ui.TextStyle{Size: fontSize, Color: look.Subtle, Mono: true}
	for line := first; line <= last; line++ {
		y := area.Y + float32(line)*v.lineH - v.scroll + (v.lineH-cellH)/2
		style.Color = look.Subtle
		if line == caretLine {
			style.Color = look.Foreground
		}
		canvas.LabelAligned(strconv.Itoa(line+1), ui.Rect{X: area.X, Y: y, Width: gutter - gutterPad, Height: cellH}, style, ui.AlignEnd)
	}
	v.paintScrollbars(canvas, textArea, look)
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
func hexColor(c ui.Color) string {
	channel := func(f float32) uint32 { return uint32(math.Round(float64(min(max(f, 0), 1) * 255))) }
	value := channel(c.Red)<<16 | channel(c.Green)<<8 | channel(c.Blue)
	s := strconv.FormatUint(uint64(value), 16)
	for len(s) < 6 {
		s = "0" + s
	}
	return "#" + s
}

// uiColor turns a theme color into a canvas color.
func uiColor(c syntax.Color) ui.Color {
	return ui.Color{Red: float32(c>>16&0xff) / 255, Green: float32(c>>8&0xff) / 255, Blue: float32(c&0xff) / 255, Alpha: 1}
}

// paintSelection fills the selected part of line; a line the selection runs past also gets its
// line break selected, one cell wide.
func (v *View) paintSelection(canvas *ui.Canvas, line int, text string, start int, y float32, selStart, selEnd int, look Look) {
	end := start + len(text)
	if selEnd < start || selStart > end {
		return
	}
	from := cellsOf(text, max(selStart-start, 0))
	to := cellsOf(text, min(selEnd-start, len(text)))
	if selEnd > end {
		to++
	}
	if to <= from {
		return
	}
	left := v.textLeft + float32(from)*v.cellW - v.scrollX
	canvas.Fill(ui.Rect{X: left, Y: y, Width: float32(to-from) * v.cellW, Height: v.lineH}, look.Selection)
}

// paintLine draws the text of line in its tokens' colors. Tabs become spaces to the next tab
// stop, and every character that is not ASCII is a run of its own at its own cell, so a wide
// or fallback glyph never moves the text after it off its column.
func (v *View) paintLine(canvas *ui.Canvas, line int, text string, y float32) {
	if text == "" {
		return
	}
	v.tokens = v.hl.Line(v.tokens[:0], line)
	v.runs = v.runs[:0]
	v.display = v.display[:0]
	defaultStyle := v.theme.Default()
	token := 0
	cells := 0
	run := -1
	runASCII := false
	for i, r := range text {
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
			weight = ui.WeightBold
		}
		italic := style.Font&syntax.Italic != 0
		width := runeCells(r, cells)
		if width == 0 {
			continue
		}
		ascii := r < 0x80
		if r == '\t' || r < 0x20 {
			r = ' '
		}
		if ascii && runASCII && run >= 0 && int(v.runs[run].Column+v.runs[run].Cells) == cells &&
			v.runs[run].Color == color && v.runs[run].Weight == weight && v.runs[run].Italic == italic {
			for range width {
				v.display = append(v.display, byte(r))
			}
			v.runs[run].Bytes += int32(width)
			v.runs[run].Cells += int32(width)
			cells += width
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
		v.runs = append(v.runs, ui.TextRun{
			Column: int32(cells), Bytes: int32(len(v.display) - before), Cells: int32(width),
			Color: color, Weight: weight, Italic: italic, Underline: style.Font&syntax.Underline != 0,
			Strike: style.Font&syntax.Strikethrough != 0,
		})
		run, runASCII = len(v.runs)-1, ascii
		cells += width
	}
	if len(v.runs) == 0 {
		return
	}
	textStyle := ui.TextStyle{Size: fontSize, Color: uiColor(defaultStyle.Foreground), Mono: true}
	width := float32(math.Ceil(float64(float32(cells)*v.cellW))) + 1
	rect := ui.Rect{X: v.textLeft - v.scrollX, Y: y + (v.lineH-v.cellH)/2, Width: width, Height: v.cellH}
	canvas.LabelRuns(string(v.display), rect, textStyle, v.cellW, v.runs)
}

// caretPoint is the top left corner of the caret.
func (v *View) caretPoint() (float32, float32) {
	line := v.text.LineOf(v.caret)
	cells := cellsOf(v.text.Line(line), v.caret-v.text.LineStart(line))
	return v.textLeft + float32(cells)*v.cellW - v.scrollX, v.area.Y + float32(line)*v.lineH - v.scroll
}

// blinkOn says whether the caret shows in this frame, and asks for the frame that turns it
// over: it is solid for a period after it moved and then blinks.
func (v *View) blinkOn(canvas *ui.Canvas) bool {
	elapsed := v.clock - v.blinkFrom
	if elapsed < 0 {
		v.blinkFrom, elapsed = v.clock, 0
	}
	phase := elapsed / blinkPeriod
	canvas.RequestFrameIn(blinkPeriod - elapsed%blinkPeriod)
	return phase%2 == 0
}

// revealCaret scrolls the least that brings the caret's line and column into view.
func (v *View) revealCaret() {
	line := v.text.LineOf(v.caret)
	top := float32(line) * v.lineH
	if top < v.scroll {
		v.scroll = top
	} else if bottom := top + v.lineH; bottom > v.scroll+v.area.Height {
		v.scroll = bottom - v.area.Height
	}
	width := v.area.X + v.area.Width - v.textLeft
	x := float32(cellsOf(v.text.Line(line), v.caret-v.text.LineStart(line))) * v.cellW
	margin := 4 * v.cellW
	if x < v.scrollX {
		v.scrollX = max(x-margin, 0)
	} else if x+v.cellW > v.scrollX+width {
		v.scrollX = x + v.cellW + margin - width
	}
}

// clampScroll keeps the scroll in range: the last line can scroll up to the top, as editors
// allow, and the text sideways as far as its widest line.
func (v *View) clampScroll() {
	maxY := max(float32(v.text.LineCount()-1)*v.lineH, 0)
	v.scroll = min(max(v.scroll, 0), maxY)
	width := v.area.X + v.area.Width - v.textLeft
	maxX := max(float32(v.widest+4)*v.cellW-width, 0)
	v.scrollX = min(max(v.scrollX, 0), maxX)
}

// paintScrollbars draws the thumbs of the scrollbars over the text's right and bottom edges
// when there is more to scroll to.
func (v *View) paintScrollbars(canvas *ui.Canvas, area ui.Rect, look Look) {
	content := float32(v.text.LineCount()-1)*v.lineH + area.Height
	if content > area.Height+0.5 {
		length := max(area.Height*area.Height/content, barMin)
		y := area.Y + (area.Height-length)*(v.scroll/(content-area.Height))
		canvas.Rounded(ui.Rect{X: area.X + area.Width - barWidth - 2, Y: y, Width: barWidth, Height: length}, barWidth/2, look.Scrollbar)
	}
	width := v.area.X + v.area.Width - v.textLeft
	contentX := float32(v.widest+4) * v.cellW
	if contentX > width+0.5 && width > 0 {
		length := max(area.Width*width/contentX, barMin)
		x := area.X + (area.Width-length)*(v.scrollX/(contentX-width))
		canvas.Rounded(ui.Rect{X: x, Y: area.Y + area.Height - barWidth - 2, Width: length, Height: barWidth}, barWidth/2, look.Scrollbar)
	}
}
