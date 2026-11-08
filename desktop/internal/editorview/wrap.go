package editorview

import (
	"bytes"
	"slices"
	"sort"
	"unicode/utf8"
)

// Soft wrapping breaks a line wider than the view into rows that fit it, so nothing scrolls
// sideways. The view lays the text out as rows: without wrapping a line is one row, so a row and
// a line are the same number. With wrapping the view keeps, for every line, how many rows it
// takes at the columns of the last paint, and from those where each line's first row is, so
// scrolling, the scrollbar and the pointer find a row's line without laying out the lines
// before it.
//
// A change of width lays out again only the lines wider than the view: how many cells a line
// takes does not depend on the width, so it is kept, and a line that fits is one row without
// reading it. Only the visible lines are broken into their rows while painting, and those rows
// are kept until the text or the width changes.

// wrapRow is where a row of a line starts: at byte at of the line, cells columns into it.
type wrapRow struct{ at, cells int }

// oneRow is the rows of a line that is not broken. Callers must not change it.
var oneRow = []wrapRow{{}}

// lineWrap is what the view keeps about a line for its rows.
type lineWrap struct {
	// cells is how many cells the line takes, or, while exact is false, at most how many: as
	// many as a tab takes for each of its bytes, which no character exceeds.
	cells int32
	exact bool
	// rows is how many rows the line takes at the view's columns.
	rows int32
}

// rowCacheLimit bounds how many lines' rows the view keeps between paints; past it they are all
// dropped and broken again as they are painted.
const rowCacheLimit = 512

// SetWrap turns soft wrapping on or off. The next paint lays the text out anew and keeps the
// line at the top of the view at the top.
func (v *View) SetWrap(on bool) { v.wrap = on }

// Wrap reports whether soft wrapping is on.
func (v *View) Wrap() bool { return v.wrap }

// wrapping says the last paint laid the text out with soft wrapping.
func (v *View) wrapping() bool { return v.wrapCols > 0 }

// wrapLine appends to dst the rows text breaks into to fit cols columns. A row breaks after a
// space or a tab, and before and after a wide character, such as a Chinese one; a word longer
// than a row breaks inside it. A character wider than a whole row takes a row of its own. Tabs
// keep the stops of the whole line, so a tab takes as many cells wrapped as unwrapped.
func wrapLine(dst []wrapRow, text string, cols int) []wrapRow {
	dst = append(dst, wrapRow{})
	if cols <= 0 {
		return dst
	}
	// start is the column the row being filled starts at, and brk the last place in it where it
	// may break; brk.at is 0 while there is none, as a row never breaks at the line's start.
	start, cells := 0, 0
	brk := wrapRow{}
	prev := rune(-1)
	for i, r := range text {
		w := runeCells(r, cells)
		if w == 0 {
			continue
		}
		if cells > start && (prev == ' ' || prev == '\t' || runeCells(prev, 0) == 2 || w == 2 && r != '\t') {
			brk = wrapRow{at: i, cells: cells}
		}
		if cells+w-start > cols && cells > start {
			row := wrapRow{at: i, cells: cells}
			if brk.at > 0 && brk.cells > start {
				row = brk
			}
			dst = append(dst, row)
			start, brk = row.cells, wrapRow{}
			// The text after the break may still leave no room for this character.
			if cells+w-start > cols && cells > start {
				dst = append(dst, wrapRow{at: i, cells: cells})
				start = cells
			}
		}
		cells += w
		prev = r
	}
	return dst
}

// rowIndex is which of rows holds byte col of their line. A column where a row starts is on
// that row, not at the end of the one before.
func rowIndex(rows []wrapRow, col int) int {
	return max(sort.Search(len(rows), func(i int) bool { return rows[i].at > col })-1, 0)
}

// rowsOf is the rows of line, whose text is text, at the view's columns. The result is shared;
// callers must not change it.
func (v *View) rowsOf(line int, text string) []wrapRow {
	if !v.wrapping() || len(text)*tabSize <= v.wrapCols {
		return oneRow
	}
	if rows, ok := v.rowCache[line]; ok {
		return rows
	}
	rows := wrapLine(nil, text, v.wrapCols)
	if v.rowCache == nil || len(v.rowCache) >= rowCacheLimit {
		v.rowCache = make(map[int][]wrapRow)
	}
	v.rowCache[line] = rows
	return rows
}

// setWrapCols lays the text out for cols columns, none when cols is 0, and scrolls so the line
// that was at the top of the view stays there. A line whose first row was partly scrolled out
// of the view stays as far out of it.
func (v *View) setWrapCols(cols int) {
	if cols == v.wrapCols {
		return
	}
	lineH := max(v.lineH, 1)
	row := int(v.scroll / lineH)
	top, sub := v.rowLine(row)
	part := float32(0)
	if sub == 0 {
		part = v.scroll - float32(row)*lineH
	}
	v.wrapCols = cols
	clear(v.rowCache)
	if cols == 0 {
		v.wraps, v.rowStart = v.wraps[:0], v.rowStart[:0]
	} else if len(v.wraps) == v.text.LineCount() {
		for line := range v.wraps {
			v.countRows(line)
		}
		v.rowsDirty = true
	}
	v.scroll = float32(v.lineRow(top))*v.lineH + part
}

// countRows works out how many rows line takes at the view's columns, reading the line only
// when it may be wider than them.
func (v *View) countRows(line int) {
	w := &v.wraps[line]
	w.rows = 1
	if int(w.cells) <= v.wrapCols {
		return
	}
	text := v.text.Line(line)
	if !w.exact {
		w.cells, w.exact = int32(cellsOf(text, len(text))), true
		if int(w.cells) <= v.wrapCols {
			return
		}
	}
	v.rowBuf = wrapLine(v.rowBuf[:0], text, v.wrapCols)
	w.rows = int32(len(v.rowBuf))
}

// ensureRows makes the rows of every line, and where each line's first row is, current.
func (v *View) ensureRows() {
	if len(v.wraps) != v.text.LineCount() {
		v.wraps = v.wraps[:0]
		size := 0
		v.text.Chunks(0, v.text.Len(), func(chunk []byte) bool {
			for {
				i := bytes.IndexByte(chunk, '\n')
				if i < 0 {
					size += len(chunk)
					return true
				}
				v.wraps = append(v.wraps, lineWrap{cells: int32(min((size+i)*tabSize, 1<<30))})
				size, chunk = 0, chunk[i+1:]
			}
		})
		v.wraps = append(v.wraps, lineWrap{cells: int32(min(size*tabSize, 1<<30))})
		for line := range v.wraps {
			v.countRows(line)
		}
		v.rowsDirty = true
	}
	if v.rowsDirty {
		v.rowStart = append(v.rowStart[:0], 0)
		row := int32(0)
		for _, w := range v.wraps {
			row += w.rows
			v.rowStart = append(v.rowStart, row)
		}
		v.rowsDirty = false
	}
}

// spliceRows follows an edit that turned lines first to oldLast into lines first to newLast:
// it lays out the new lines and keeps the counts of all the others.
func (v *View) spliceRows(first, oldLast, newLast, oldCount int) {
	clear(v.rowCache)
	if !v.wrapping() || len(v.wraps) != oldCount {
		v.wraps = v.wraps[:0]
		return
	}
	fresh := make([]lineWrap, newLast-first+1)
	for i := range fresh {
		line := first + i
		size := v.text.LineEnd(line) - v.text.LineStart(line)
		fresh[i] = lineWrap{cells: int32(min(size*tabSize, 1<<30))}
	}
	v.wraps = slices.Replace(v.wraps, first, oldLast+1, fresh...)
	for line := first; line <= newLast; line++ {
		v.countRows(line)
	}
	v.rowsDirty = true
}

// forgetRows drops the layout, for a text that changed as a whole.
func (v *View) forgetRows() {
	clear(v.rowCache)
	v.wraps = v.wraps[:0]
}

// rowCount is how many rows the text takes.
func (v *View) rowCount() int {
	if !v.wrapping() {
		return v.text.LineCount()
	}
	v.ensureRows()
	return int(v.rowStart[len(v.rowStart)-1])
}

// lineRow is the first row of line.
func (v *View) lineRow(line int) int {
	if !v.wrapping() {
		return line
	}
	v.ensureRows()
	return int(v.rowStart[min(max(line, 0), len(v.wraps)-1)])
}

// rowLine is the line row is on and which of the line's rows it is. A row past the last is the
// last line's.
func (v *View) rowLine(row int) (int, int) {
	if !v.wrapping() {
		line := min(max(row, 0), v.text.LineCount()-1)
		return line, 0
	}
	v.ensureRows()
	lines := len(v.wraps)
	line := min(sort.Search(lines, func(i int) bool { return int(v.rowStart[i+1]) > row }), lines-1)
	return line, min(max(row-int(v.rowStart[line]), 0), int(v.wraps[line].rows)-1)
}

// caretPlace is the caret's line, the line's text and rows, and which row the caret is on.
func (v *View) caretPlace() (int, string, []wrapRow, int) {
	line := v.text.LineOf(v.caret)
	text := v.text.Line(line)
	rows := v.rowsOf(line, text)
	return line, text, rows, rowIndex(rows, v.caret-v.text.LineStart(line))
}

// caretRow is the row the caret is on.
func (v *View) caretRow() int {
	line, _, _, k := v.caretPlace()
	return v.lineRow(line) + k
}

// columnOnRow is the byte column of line nearest cells columns into its row sub. A column past
// the end of a row the line goes on from is the start of the row's last character: the end of
// such a row is where the next row starts, and the caret there shows on the next row.
func (v *View) columnOnRow(line, sub int, cells float32) int {
	text := v.text.Line(line)
	rows := v.rowsOf(line, text)
	sub = min(max(sub, 0), len(rows)-1)
	row := rows[sub]
	end := len(text)
	if sub+1 < len(rows) {
		end = rows[sub+1].at
	}
	col := columnIn(text, row.at, end, row.cells, float32(row.cells)+cells)
	if sub+1 < len(rows) && col >= end && end > row.at {
		_, size := utf8.DecodeLastRuneInString(text[row.at:end])
		col = end - size
	}
	return col
}
