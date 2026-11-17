package textview

import (
	"math"
	"unicode/utf8"
)

// layout breaks the lines into rows for a text width, when the view wraps. A view that
// does not wrap has a row for each line and keeps no list of them, so a console of many
// thousands of lines costs nothing to lay out.
func (v *View) layout(width float32) {
	src := v.spec.Source
	key := layoutKey{revision: v.spec.Revision, width: width, cellW: v.cellW, wrap: v.spec.Wrap}
	if src != nil {
		key.first, key.count = src.First(), src.Count()
	}
	if key.revision != 0 && key == v.laid {
		return
	}
	v.laid = key
	v.rows = v.rows[:0]
	v.wrapCols = 0
	if !v.spec.Wrap || src == nil || v.cellW <= 0 {
		return
	}
	// Two pixels are kept back for the pixel a label is drawn wider (paint.go's flush) and
	// its rounding, so a full row stays inside the view.
	cols := int((width - 2*v.spec.PadX - 2) / v.cellW)
	if cols <= 0 {
		// Not painted yet: a row for each line until the width is known.
		for n := src.First(); n < src.First()+src.Count(); n++ {
			v.rows = append(v.rows, row{line: n, from: 0, to: len(src.Line(n))})
		}
		return
	}
	v.wrapCols = cols
	for n := src.First(); n < src.First()+src.Count(); n++ {
		v.rows = wrapLine(v.rows, n, src.Line(n), max(cols-v.trailCells(n), 1))
	}
}

// trailCells is how many cells line n's trail and the gap before it take from the line's
// text, 0 when it has none.
func (v *View) trailCells(n int) int {
	if v.spec.Trail == nil || v.canvas == nil || v.cellW <= 0 {
		return 0
	}
	t := v.spec.Trail(n)
	if t.Text == "" {
		return 0
	}
	return int(math.Ceil(float64((v.canvas.TextWidthStyle(t.Text, t.Style) + trailGap) / v.cellW)))
}

// wrapLine appends the rows of one line cols columns wide: each ends after the last space
// that fits, or at the column limit when no space does.
func wrapLine(rows []row, n int, text string, cols int) []row {
	start, cells, space := 0, 0, -1
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		width := runeCells(r, cells)
		if cells+width > cols && cells > 0 {
			end := i
			if space > start {
				end = space
			}
			rows = append(rows, row{line: n, from: start, to: end})
			start, space = end, -1
			cells = cellsOf(text[start:i], 0)
			continue
		}
		cells += width
		i += size
		if r == ' ' || r == '\t' {
			space = i
		}
	}
	return append(rows, row{line: n, from: start, to: len(text)})
}

// rowCount is how many rows the text takes.
func (v *View) rowCount() int {
	if v.spec.Source == nil {
		return 0
	}
	if v.spec.Wrap {
		return len(v.rows)
	}
	return v.spec.Source.Count()
}

// rowBytes is the line row index shows and the bytes of it the row holds.
func (v *View) rowBytes(index int) (line, from, to int) {
	if v.spec.Wrap {
		r := v.rows[index]
		return r.line, r.from, r.to
	}
	line = v.spec.Source.First() + index
	return line, 0, len(v.spec.Source.Line(line))
}

// rowLine is the line row index shows.
func (v *View) rowLine(index int) int {
	if v.spec.Wrap {
		if index >= len(v.rows) {
			return v.spec.Source.First() + v.spec.Source.Count()
		}
		return v.rows[index].line
	}
	return v.spec.Source.First() + index
}

// lastRow reports whether row index is the last row of its line.
func (v *View) lastRow(index int) bool {
	return !v.spec.Wrap || index+1 >= len(v.rows) || v.rows[index+1].line != v.rows[index].line
}

// firstRowOf is the index of line n's first row.
func (v *View) firstRowOf(n int) (int, bool) {
	src := v.spec.Source
	if src == nil || n < src.First() || n >= src.First()+src.Count() {
		return 0, false
	}
	if !v.spec.Wrap {
		return n - src.First(), true
	}
	for i, r := range v.rows {
		if r.line == n {
			return i, true
		}
	}
	return 0, false
}

// rowRange is the rows the clip shows, from the first to the one after the last.
func (v *View) rowRange() (int, int) {
	count := v.rowCount()
	if v.lineH <= 0 || count == 0 {
		return 0, 0
	}
	top := v.clip.Y - v.rect.Y - v.spec.PadY
	from := max(int(math.Floor(float64(top/v.lineH))), 0)
	to := min(int(math.Ceil(float64((top+v.clip.Height)/v.lineH))), count)
	return min(from, count), max(to, min(from, count))
}
