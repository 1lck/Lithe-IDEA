package term

import (
	"strings"
	"unicode"
)

// Position identifies one visible terminal cell.
type Position struct {
	Row, Column int
}

// Point is one cell of the retained buffer. Line counts as LineNumber does, so
// a Point keeps naming the same text while the view scrolls and while the
// history drops its oldest lines. Selections use it to stay put under scrolling.
type Point struct {
	Line   uint64
	Column int
}

// SetWordSeparators overrides the punctuation that separates words in selections.
// An empty value keeps the Unicode-based default classification.
func (t *Terminal) SetWordSeparators(separators string) {
	t.wordSeparators = separators
}

// PointAt is the buffer point under a view position.
func (t *Terminal) PointAt(position Position) Point {
	return Point{Line: t.LineNumber(position.Row), Column: position.Column}
}

// SelectedText returns the cells between two inclusive visible positions.
// Soft-wrapped rows are joined; hard line endings remain newlines.
func (t *Terminal) SelectedText(anchor, focus Position) string {
	return t.SelectedRange(t.PointAt(t.clampPosition(anchor)), t.PointAt(t.clampPosition(focus)))
}

// SelectedRange returns the cells between two inclusive buffer points, which
// may lie outside the view. Points beyond the retained lines clamp to them.
// Soft-wrapped rows are joined; hard line endings remain newlines.
func (t *Terminal) SelectedRange(anchor, focus Point) string {
	base, count := t.lineBase(), uint64(t.bufferLineCount())
	if count == 0 {
		return ""
	}
	anchor, focus = t.clampPoint(anchor, base, count), t.clampPoint(focus, base, count)
	if pointLess(focus, anchor) {
		anchor, focus = focus, anchor
	}

	var result strings.Builder
	result.Grow(int(min(focus.Line-anchor.Line+1, 1<<16)) * (t.cols + 1))
	for line := anchor.Line; line <= focus.Line; line++ {
		from, to := 0, t.cols-1
		if line == anchor.Line {
			from = anchor.Column
		}
		if line == focus.Line {
			to = focus.Column
		}
		row := t.rowOf(t.bufferLine(int(line - base)))
		writeSelectedCells(&result, row, from, to)
		if line < focus.Line && !row.Wrapped {
			result.WriteByte('\n')
		}
	}
	return result.String()
}

// lineBase is the line number of retained-buffer index 0.
func (t *Terminal) lineBase() uint64 {
	if t.onAlt {
		return t.scrolled + 1
	}
	return t.scrolled - uint64(t.histCount) + 1
}

func (t *Terminal) clampPoint(point Point, base, count uint64) Point {
	point.Line = min(max(point.Line, base), base+count-1)
	point.Column = clampInt(point.Column, 0, t.cols-1)
	return point
}

func pointLess(left, right Point) bool {
	return left.Line < right.Line || left.Line == right.Line && left.Column < right.Column
}

// WordBounds returns the inclusive run of like cells around position. Letters,
// numbers, and underscores form words; spaces and punctuation form their own runs.
func (t *Terminal) WordBounds(position Position) (Position, Position) {
	position = t.clampPosition(position)
	start, end := t.wordColumns(t.Row(position.Row), position.Column)
	return Position{Row: position.Row, Column: start}, Position{Row: position.Row, Column: end}
}

// WordRange is WordBounds for a point of the retained buffer, which may lie
// outside the view. Points beyond the retained lines clamp to them.
func (t *Terminal) WordRange(point Point) (Point, Point) {
	base, count := t.lineBase(), uint64(t.bufferLineCount())
	if count == 0 {
		return point, point
	}
	point = t.clampPoint(point, base, count)
	start, end := t.wordColumns(t.rowOf(t.bufferLine(int(point.Line-base))), point.Column)
	return Point{Line: point.Line, Column: start}, Point{Line: point.Line, Column: end}
}

// LineRange is the whole logical line holding point: every row the terminal
// soft-wrapped it into, from the first cell of the first to the last cell of the
// last. Points beyond the retained lines clamp to them.
func (t *Terminal) LineRange(point Point) (Point, Point) {
	base, count := t.lineBase(), uint64(t.bufferLineCount())
	if count == 0 {
		return point, point
	}
	point = t.clampPoint(point, base, count)
	index := int(point.Line - base)
	first, last := t.linkGroupStart(index), t.linkGroupEnd(index)-1
	return Point{Line: base + uint64(first)}, Point{Line: base + uint64(last), Column: t.cols - 1}
}

// wordColumns is the inclusive column range of the run of like cells around column.
func (t *Terminal) wordColumns(row Row, column int) (int, int) {
	if column < len(row.Cells) && row.Cells[column].Attr&WideTail != 0 && column > 0 {
		column--
	}
	kind := t.selectedCellKind(row.Cells, column)
	start := column
	for start > 0 {
		previous := start - 1
		if previous < len(row.Cells) && row.Cells[previous].Attr&WideTail != 0 && previous > 0 {
			previous--
		}
		if t.selectedCellKind(row.Cells, previous) != kind {
			break
		}
		start = previous
	}
	end := column
	for {
		next := end + selectedCellWidth(row.Cells, end)
		if next >= t.cols || t.selectedCellKind(row.Cells, next) != kind {
			break
		}
		end = next
	}
	end += selectedCellWidth(row.Cells, end) - 1
	return start, min(end, t.cols-1)
}

func (t *Terminal) clampPosition(position Position) Position {
	position.Row = clampInt(position.Row, 0, t.rows-1)
	position.Column = clampInt(position.Column, 0, t.cols-1)
	return position
}

func positionLess(left, right Position) bool {
	return left.Row < right.Row || left.Row == right.Row && left.Column < right.Column
}

func writeSelectedCells(result *strings.Builder, row Row, from, to int) {
	to = selectedRowEnd(row, from, to)
	mark := 0
	for column := from; column <= to; column++ {
		for mark < len(row.Marks) && int(row.Marks[mark].Col) < column {
			mark++
		}
		if column >= len(row.Cells) {
			result.WriteByte(' ')
			continue
		}
		cell := row.Cells[column]
		if cell.Attr&WideTail != 0 {
			continue
		}
		character := cell.R
		if character == 0 {
			character = ' '
		}
		result.WriteRune(character)
		for mark < len(row.Marks) && int(row.Marks[mark].Col) == column {
			result.WriteRune(row.Marks[mark].R)
			mark++
		}
	}
}

func selectedRowEnd(row Row, from, to int) int {
	for to >= from {
		if to >= len(row.Cells) {
			to--
			continue
		}
		cell := row.Cells[to]
		if cell.Attr&WideTail != 0 {
			if to > from && selectedCellContent(row, to-1) {
				return to
			}
			to--
			continue
		}
		if selectedCellContent(row, to) {
			return to
		}
		to--
	}
	return from - 1
}

func selectedCellContent(row Row, column int) bool {
	if column >= 0 && column < len(row.Cells) {
		character := row.Cells[column].R
		if character != 0 && character != ' ' {
			return true
		}
	}
	for _, mark := range row.Marks {
		if int(mark.Col) == column {
			return true
		}
		if int(mark.Col) > column {
			break
		}
	}
	return false
}

type cellKind uint8

const (
	cellBlank cellKind = iota
	cellWord
	cellPunctuation
)

func (t *Terminal) selectedCellKind(cells []Cell, column int) cellKind {
	if column < 0 || column >= len(cells) || cells[column].R == 0 || unicode.IsSpace(cells[column].R) {
		return cellBlank
	}
	if t.wordSeparators != "" {
		if strings.ContainsRune(t.wordSeparators, cells[column].R) {
			return cellPunctuation
		}
		return cellWord
	}
	if cells[column].R == '_' || unicode.IsLetter(cells[column].R) || unicode.IsNumber(cells[column].R) {
		return cellWord
	}
	return cellPunctuation
}

func selectedCellWidth(cells []Cell, column int) int {
	if column >= 0 && column < len(cells) && cells[column].Attr&WideHead != 0 {
		return 2
	}
	return 1
}

// TokenAt returns the run of non-blank text around a visible cell, without the
// brackets, quotes and sentence punctuation that usually wrap it: what a person
// would call "that address" or "that path" when pointing at it. It is empty on a
// blank cell. The token stays on its row, so a soft-wrapped path is cut where the
// wrap fell.
func (t *Terminal) TokenAt(position Position) string {
	position = t.clampPosition(position)
	row := t.Row(position.Row)
	blank := func(column int) bool {
		if column >= len(row.Cells) {
			return true
		}
		cell := row.Cells[column]
		return cell.Attr&WideTail == 0 && (cell.R == 0 || unicode.IsSpace(cell.R))
	}
	if blank(position.Column) {
		return ""
	}
	start, end := position.Column, position.Column
	for start > 0 && !blank(start-1) && position.Column-start < 512 {
		start--
	}
	for end+1 < t.cols && !blank(end+1) && end-position.Column < 512 {
		end++
	}
	text := t.SelectedText(Position{Row: position.Row, Column: start}, Position{Row: position.Row, Column: end})
	text = strings.TrimLeft(text, "([{<\"'`")
	return strings.TrimRight(text, ")]}>\"'`,;:!?.")
}
