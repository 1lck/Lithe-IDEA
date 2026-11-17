package textview

import (
	"math"
	"unicode/utf8"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// labelWidth is how wide one label of a row is at most, as the editor cuts its rows
// (editorview's labelWidth), so a very long line is not one huge texture.
const labelWidth = float32(2048)

// replacementChar is what a byte that is not UTF-8 shows.
const replacementChar = "\uFFFD"

// painter gathers the runs of one label of a row.
type painter struct {
	v      *View
	canvas *gfx.Canvas
	runs   []gfx.TextRun
	style  gfx.TextStyle
	left   float32
	y      float32
	line   int
	// fit is how many cells of the row are drawn before the ellipsis of a line cut short,
	// and -1 when the row is drawn whole.
	fit int
}

// paint draws the rows on screen: the selection behind them, then each row on the
// fixed-pitch grid in its spans' colors. It declares the view's hit again with the text
// cursor, and the links with the hand.
func (v *View) paint(dc *ui.DrawContext) {
	canvas := dc.Canvas
	src := v.spec.Source
	if src == nil {
		return
	}
	v.rect = dc.Rect
	v.clip = visible(canvas, dc.Rect)
	if v.spec.Wrap && dc.Rect.Width != v.width {
		v.width = dc.Rect.Width
		v.layout(v.width)
		canvas.RequestFrame() // the rows changed, and with them the height declared
	}
	if v.pressed && v.moved {
		v.extendTo(v.pointer)
	}
	canvas.HitWithOptions(v.id, v.clip, dc.Label, gfx.HitOptions{Role: gfx.RoleGroup, Cursor: gfx.PointerCursorText})
	from, to := v.rowRange()
	selFrom, selTo, selected := v.Selection.Range(src)
	p := &painter{v: v, canvas: canvas, style: v.spec.Font, left: v.rect.X + v.spec.PadX}
	p.style.Mono = true
	limit := max(int(labelWidth/v.cellW), 1)
	cols := max(int(math.Ceil(float64((v.clip.X+v.clip.Width-p.left)/v.cellW))), 0)
	// The columns a line fits in before its trail, less the pixels a label is drawn wider.
	room := int((v.rect.Width - 2*v.spec.PadX - 2) / v.cellW)
	v.trails = v.trails[:0]
	for index := from; index < to; index++ {
		line, start, end := v.rowBytes(index)
		text := src.Line(line)
		p.line = line
		p.y = v.rect.Y + v.spec.PadY + float32(index)*v.lineH
		if v.spec.LineBackground != nil {
			if color := v.spec.LineBackground(line); color.Alpha > 0 {
				canvas.Fill(gfx.Rect{X: v.rect.X, Y: p.y, Width: v.rect.Width, Height: v.lineH}, color)
			}
		}
		var trail Trail
		if v.spec.Trail != nil && start == 0 {
			trail = v.spec.Trail(line)
		}
		v.spans = v.spans[:0]
		if v.spec.Spans != nil && text != "" {
			v.spans = v.spec.Spans(line, text, v.spans)
		}
		p.fit = -1
		if v.spec.Ellipsis && !v.spec.Wrap {
			fit := room
			if trail.Text != "" {
				fit -= v.trailCells(line)
			}
			if fit = max(fit, 1); cellsOf(text, 0) > fit {
				p.fit = fit - 1
			}
		}
		p.decorate(text, start, end)
		if selected && line >= selFrom.Line && line <= selTo.Line {
			v.paintSelection(canvas, text, line, start, end, index, selFrom, selTo, p.left, p.y, p.fit)
		}
		if p.fit < 0 {
			p.row(text, start, end, cols, limit)
		} else {
			p.cut(text, start, end, min(cols, p.fit), limit)
		}
		if trail.Text != "" {
			p.trail(line, trail)
		}
	}
}

// cut draws a row cut short: the columns before fit, then the ellipsis in the color of the
// span the cut fell in.
func (p *painter) cut(text string, start, end, fit, limit int) {
	stop := p.row(text, start, end, fit, limit)
	color := p.style.Color
	for _, span := range p.v.spans {
		if span.From <= stop && stop < span.To {
			color = p.spanColor(span)
			break
		}
	}
	p.runs = append(p.runs, gfx.TextRun{Bytes: int32(len(ellipsis)), Cells: 1, Color: color})
	p.flush(ellipsis, p.fit, p.fit+1)
}

// trail draws line n's trail at the view's right edge, centered on the row, and keeps where
// a Button trail went so a click on it presses it.
func (p *painter) trail(n int, t Trail) {
	v := p.v
	width := p.canvas.TextWidthStyle(t.Text, t.Style)
	height := t.Style.Size + 7 // the height of one line of a ui.Text
	rect := gfx.Rect{X: v.rect.X + v.rect.Width - v.spec.PadX - width, Y: p.y + (v.lineH-height)/2, Width: width + 1, Height: height}
	p.canvas.Label(t.Text, rect, t.Style)
	if t.Button {
		hit := gfx.Rect{X: rect.X, Y: p.y, Width: rect.Width, Height: v.lineH}
		p.canvas.HitWithOptions(v.id, hit, t.Text, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
		v.trails = append(v.trails, trailHit{line: n, rect: hit})
	}
}

// spanColor is the color a span is drawn in: its Hover color while the pointer is over its
// link.
func (p *painter) spanColor(span Span) gfx.Color {
	v := p.v
	if span.Link && span.Hover.Alpha > 0 && v.hovering && v.hover.Byte == span.From && p.line == v.hover.Line {
		return span.Hover
	}
	return span.Color
}

// visible is the part of r inside every clip the canvas paints with.
func visible(canvas *gfx.Canvas, r gfx.Rect) gfx.Rect {
	for _, clip := range canvas.Clips() {
		b := clip.Bounds
		x0, y0 := max(r.X, b.X), max(r.Y, b.Y)
		x1, y1 := min(r.X+r.Width, b.X+b.Width), min(r.Y+r.Height, b.Y+b.Height)
		r = gfx.Rect{X: x0, Y: y0, Width: max(x1-x0, 0), Height: max(y1-y0, 0)}
	}
	return r
}

// paintSelection fills the selected part of a row. A selection that goes on past the
// line's end covers one cell more, for the newline it holds.
func (v *View) paintSelection(canvas *gfx.Canvas, text string, line, start, end, index int, from, to Point, left, y float32, fit int) {
	a, b := start, end
	if line == from.Line {
		a = max(a, from.Byte)
	}
	if line == to.Line {
		b = min(b, to.Byte)
	}
	if a > b || a == b && !(line < to.Line && v.lastRow(index) && a == end) {
		return
	}
	x0 := cellsOf(text[start:a], 0)
	x1 := x0 + cellsOf(text[a:b], x0)
	if line < to.Line && v.lastRow(index) && b == end {
		x1++
	}
	if fit >= 0 {
		// A line cut short is selected up to its ellipsis, which stands for the rest.
		x0, x1 = min(x0, fit+1), min(x1, fit+1)
		if x0 >= x1 {
			return
		}
	}
	canvas.Fill(gfx.Rect{X: left + float32(x0)*v.cellW, Y: y, Width: float32(x1-x0) * v.cellW, Height: v.lineH}, v.spec.Selection)
}

// row draws the bytes start to end of a line, the columns before cols of it, as labels
// of at most limit columns: each character on its cells, in the color of the span it is
// in. A tab or a control character leaves its cells empty; a combining mark is not drawn.
func (p *painter) row(text string, start, end, cols, limit int) int {
	v := p.v
	span := 0
	cells := 0
	run, runASCII := -1, false
	label, labelEnd, labelAt, labelTo := -1, 0, start, start
	for i := start; i < end; {
		at := i
		r, size := utf8.DecodeRuneInString(text[i:])
		i += size
		width := runeCells(r, cells)
		if width == 0 {
			p.flush(text[labelAt:labelTo], label, labelEnd)
			label = -1
			continue
		}
		if cells >= cols || p.fit >= 0 && cells+width > cols {
			p.flush(text[labelAt:labelTo], label, labelEnd)
			return at
		}
		for span < len(v.spans) && v.spans[span].To <= at {
			span++
		}
		var style Span
		styled := span < len(v.spans) && v.spans[span].From <= at
		if styled {
			style = v.spans[span]
		}
		if r == '\t' || r < 0x20 {
			p.flush(text[labelAt:labelTo], label, labelEnd)
			label = -1
			cells += width
			continue
		}
		invalid := r == utf8.RuneError && size == 1
		if label < 0 || invalid || cells+width-label > limit {
			p.flush(text[labelAt:labelTo], label, labelEnd)
			label, labelAt, labelTo, run = cells, at, at, -1
		}
		color, weight := p.style.Color, float32(0)
		if styled {
			color = p.spanColor(style)
			if style.Bold {
				weight = gfx.WeightBold
			}
		}
		italic := styled && style.Italic
		ascii := r < 0x80
		if ascii && runASCII && run >= 0 && p.runs[run].Color == color && p.runs[run].Weight == weight &&
			p.runs[run].Italic == italic && p.runs[run].Underline == style.Underline && p.runs[run].Strike == style.Strike {
			p.runs[run].Bytes += int32(size)
			p.runs[run].Cells += int32(width)
		} else {
			bytes := size
			if invalid {
				bytes = len(replacementChar)
			}
			p.runs = append(p.runs, gfx.TextRun{
				Column: int32(cells - label), Bytes: int32(bytes), Cells: int32(width),
				Color: color, Weight: weight, Italic: italic, Underline: style.Underline, Strike: style.Strike,
			})
			run, runASCII = len(p.runs)-1, ascii
		}
		cells += width
		labelEnd, labelTo = cells, i
		if invalid {
			p.flush(replacementChar, label, labelEnd)
			label = -1
		}
	}
	p.flush(text[labelAt:labelTo], label, labelEnd)
	return end
}

// decorate fills the backgrounds of a row's spans and declares the hits of its links with
// the hand cursor, named by their text, under the view's own identity so a press on a link
// still selects.
func (p *painter) decorate(text string, start, end int) {
	v := p.v
	for _, span := range v.spans {
		if span.Background.Alpha <= 0 && !span.Link {
			continue
		}
		a, b := max(span.From, start), min(span.To, end)
		if a >= b {
			continue
		}
		x0 := cellsOf(text[start:a], 0)
		x1 := x0 + cellsOf(text[a:b], x0)
		if p.fit >= 0 {
			if x0, x1 = min(x0, p.fit+1), min(x1, p.fit+1); x0 >= x1 {
				continue
			}
		}
		rect := gfx.Rect{X: p.left + float32(x0)*v.cellW, Y: p.y, Width: float32(x1-x0) * v.cellW, Height: v.lineH}
		if span.Background.Alpha > 0 {
			p.canvas.Fill(rect, span.Background)
		}
		if span.Link {
			label := span.Label
			if label == "" {
				label = text[a:b]
			}
			p.canvas.HitWithOptions(v.id, rect, label, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand})
		}
	}
}

// flush draws the runs gathered for a label from column start to column end and empties
// them for the next label.
func (p *painter) flush(value string, start, end int) {
	if len(p.runs) == 0 {
		return
	}
	v := p.v
	width := float32(math.Ceil(float64(float32(end-start)*v.cellW))) + 1
	rect := gfx.Rect{X: p.left + float32(start)*v.cellW, Y: p.y + (v.lineH-v.cellH)/2, Width: width, Height: v.cellH}
	p.canvas.LabelRuns(value, rect, p.style, v.cellW, p.runs)
	p.runs = p.runs[:0]
}
