package editorview

import (
	"context"
	"math"
	"slices"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/vivaui/viva/gfx"
)

// InlayHintSpec describes a Core-normalized virtual hint to lay out against a
// captured document.
type InlayHintSpec struct {
	ID           int
	Line         int
	UTF16Column  int
	Label        string
	PaddingLeft  bool
	PaddingRight bool
	Interactive  bool
}

// PreparedInlayHints is immutable geometry for one document revision.
type PreparedInlayHints struct {
	text     rope.Rope
	revision int
	lines    map[int]inlayLine
	order    []int
	widest   int
	maxRuns  int
}

type inlayLine struct {
	hints []preparedInlayHint
	cells int
}

type preparedInlayHint struct {
	id          int
	byteCol     int
	cell        int
	label       string
	padLeft     int
	textCells   int
	cells       int
	interactive bool
	runs        []gfx.TextRun
}

type inlayState struct {
	prepared PreparedInlayHints
	wraps    map[int][]wrapRow
	// Additional wrapped rows are sparse. Updating viewport hints must never
	// recompute the base row positions of a complete document.
	rowDeltas []inlayRowDelta
}

type inlayRowDelta struct{ line, total int }

// PrepareInlayHints calculates virtual positions off the window thread. Very
// long lines use the editor's paged renderer and get no inline decorations.
func PrepareInlayHints(ctx context.Context, text rope.Rope, revision int, specs []InlayHintSpec) (PreparedInlayHints, error) {
	if err := ctx.Err(); err != nil {
		return PreparedInlayHints{}, err
	}
	out := PreparedInlayHints{text: text, revision: revision}
	byLine := make(map[int][]InlayHintSpec)
	for _, spec := range specs {
		if spec.Line < 0 || spec.Line >= text.LineCount() || spec.Label == "" {
			continue
		}
		if text.LineEnd(spec.Line)-text.LineStart(spec.Line) <= longLine {
			byLine[spec.Line] = append(byLine[spec.Line], spec)
		}
	}
	if len(byLine) == 0 {
		return out, nil
	}
	out.lines = make(map[int]inlayLine, len(byLine))
	for line, items := range byLine {
		if err := ctx.Err(); err != nil {
			return PreparedInlayHints{}, err
		}
		slices.SortStableFunc(items, func(a, b InlayHintSpec) int {
			switch {
			case a.UTF16Column < b.UTF16Column:
				return -1
			case a.UTF16Column > b.UTF16Column:
				return 1
			default:
				return 0
			}
		})
		value, _ := text.Substring(text.LineStart(line), text.LineEnd(line))
		hints := make([]preparedInlayHint, 0, len(items))
		at, cell := 0, 0
		for _, item := range items {
			label, runs, textCells := prepareInlayLabel(item.Label)
			if textCells == 0 {
				continue
			}
			byteCol := inlayByteColumn(value, item.UTF16Column)
			cell = inlayCells(value[at:byteCol], cell)
			left, right := 0, 0
			if item.PaddingLeft {
				left = 1
			}
			if item.PaddingRight {
				right = 1
			}
			hintCells := left + textCells + right
			hints = append(hints, preparedInlayHint{
				id: item.ID, byteCol: byteCol, cell: cell, label: label,
				padLeft: left, textCells: textCells, cells: hintCells,
				interactive: item.Interactive, runs: runs,
			})
			out.maxRuns = max(out.maxRuns, len(runs))
			at, cell = byteCol, cell+hintCells
		}
		if len(hints) > 0 {
			cells := inlayCells(value[at:], cell)
			out.lines[line] = inlayLine{hints: hints, cells: cells}
			out.order = append(out.order, line)
			out.widest = max(out.widest, cells)
		}
	}
	slices.Sort(out.order)
	return out, nil
}

func inlayByteColumn(line string, column int) int {
	line = strings.TrimSuffix(line, "\r")
	for i, r := range line {
		units := 1
		if r > 0xffff {
			units = 2
		}
		if column < units {
			return i
		}
		column -= units
	}
	return len(line)
}

func prepareInlayLabel(label string) (string, []gfx.TextRun, int) {
	// One hint occupies one row. Keep the label bytes aligned with the runs
	// handed to Viva even when the server supplies controls or invalid UTF-8.
	label = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, label)
	runs := make([]gfx.TextRun, 0, min(len(label), 4))
	cells := 0
	ascii := false
	for _, r := range label {
		size, width := utf8.RuneLen(r), runeCells(r, 0)
		if r < utf8.RuneSelf && ascii {
			last := &runs[len(runs)-1]
			last.Bytes += int32(size)
			last.Cells += int32(width)
		} else {
			runs = append(runs, gfx.TextRun{Column: int32(cells), Bytes: int32(size), Cells: int32(width)})
		}
		ascii = r < utf8.RuneSelf
		cells += width
	}
	return label, runs, cells
}

func inlayCells(text string, cells int) int {
	for _, r := range text {
		cells += runeCells(r, cells)
	}
	return cells
}

// SetPreparedInlayHints installs geometry only for the exact document snapshot.
func (v *View) SetPreparedInlayHints(prepared PreparedInlayHints) bool {
	if v.revision != prepared.revision || !v.text.Same(prepared.text) {
		return false
	}
	if len(prepared.lines) == 0 {
		v.ClearInlayHints()
		return true
	}
	v.replaceInlayHints(prepared)
	v.inlayRuns = slices.Grow(v.inlayRuns[:0], prepared.maxRuns)
	return true
}

// ClearInlayHints removes virtual hints and leaves the reader at the same line.
func (v *View) ClearInlayHints() bool {
	if !v.HasInlayHints() {
		return false
	}
	v.replaceInlayHints(PreparedInlayHints{})
	return true
}

func (v *View) replaceInlayHints(prepared PreparedInlayHints) {
	v.mm.key.valid = false
	if !v.wrapping() || v.lineH <= 0 {
		v.inlay = inlayState{prepared: prepared}
		return
	}
	row := int(v.scroll / v.lineH)
	line, sub := v.rowLine(row)
	part := v.scroll - float32(row)*v.lineH

	v.inlay = inlayState{prepared: prepared}
	v.reflowInlayRows()
	sub = min(sub, max(len(v.rowsOf(v.ref(line)))-1, 0))
	v.scroll = float32(v.lineRow(line)+sub)*v.lineH + part
}

func (v *View) reflowInlayRows() {
	v.inlay.wraps = nil
	v.inlay.rowDeltas = v.inlay.rowDeltas[:0]
	if !v.wrapping() || !v.HasInlayHints() {
		return
	}
	v.mm.key.valid = false
	v.ensureRows()
	prepared := &v.inlay.prepared
	v.inlay.wraps = make(map[int][]wrapRow)
	total := 0
	for _, line := range prepared.order {
		if v.fold.hides(line) {
			continue
		}
		data := prepared.lines[line]
		rows := oneRow
		if data.cells > v.wrapCols {
			rows = wrapLineWithHints(nil, v.ref(line).text, data.hints, v.wrapCols)
			v.inlay.wraps[line] = rows
		}
		if change := len(rows) - int(v.wraps[line].rows); change != 0 {
			total += change
			v.inlay.rowDeltas = append(v.inlay.rowDeltas, inlayRowDelta{line: line, total: total})
		}
	}
}

func (v *View) inlayRowsBefore(line int) int {
	deltas := v.inlay.rowDeltas
	i := sort.Search(len(deltas), func(i int) bool { return deltas[i].line >= line })
	if i == 0 {
		return 0
	}
	return deltas[i-1].total
}

// HasInlayHints reports whether the view has active inline hints.
func (v *View) HasInlayHints() bool { return len(v.inlay.prepared.lines) > 0 }

func (v *View) lineInlayHints(line int) []preparedInlayHint {
	if !v.HasInlayHints() {
		return nil
	}
	return v.inlay.prepared.lines[line].hints
}

// CellWidth returns the measured width of one editor cell.
func (v *View) CellWidth() float32 { return v.cellW }

// VisibleLineRange returns the inclusive zero-based range of document lines
// at the current scroll position using the last painted viewport dimensions.
func (v *View) VisibleLineRange() (firstLine, lastLine int, ok bool) {
	firstRow, lastRow, ok := v.viewportRows(0)
	if !ok {
		return 0, 0, false
	}
	firstLine, _ = v.rowLine(firstRow)
	lastLine, _ = v.rowLine(lastRow)
	return firstLine, lastLine, true
}

// LineSpan is a contiguous range of zero-based document lines, both inclusive.
type LineSpan struct{ First, Last int }

// ViewportLineRanges appends contiguous spans of visible lines to dst. The
// margin extends the viewport in screen rows before mapping to document lines,
// so neither the viewport nor the margin includes any lines hidden by folding.
func (v *View) ViewportLineRanges(dst []LineSpan, marginRows int) []LineSpan {
	firstRow, lastRow, ok := v.viewportRows(marginRows)
	if !ok {
		return dst
	}
	first, _ := v.rowLine(firstRow)
	last, _ := v.rowLine(lastRow)
	if len(v.fold.collapsed) == 0 || first == last {
		return append(dst, LineSpan{first, last})
	}

	span := LineSpan{first, first}
	for line := first; line < last; {
		next := line + 1
		if v.fold.hides(next) {
			// Hidden lines share the next visible line's first row. Map that row
			// back once, regardless of how many logical lines the fold hides.
			next, _ = v.rowLine(v.rowStartForLine(next))
			dst = append(dst, span)
			span.First = next
		}
		span.Last = next
		line = next
	}
	return append(dst, span)
}

func (v *View) viewportRows(marginRows int) (firstRow, lastRow int, ok bool) {
	if !v.painted || v.lineH <= 0 {
		return 0, 0, false
	}
	rows := v.rowCount()
	if rows <= 0 {
		return 0, 0, false
	}
	firstRow = min(max(int(v.scroll/v.lineH), 0), rows-1)
	lastRow = min(max(int(math.Ceil(float64((v.scroll+v.area.Height)/v.lineH)))-1, firstRow), rows-1)
	marginRows = max(marginRows, 0)
	return max(firstRow-marginRows, 0), lastRow + min(marginRows, rows-1-lastRow), true
}

// InlayHintRequestEnd returns the exclusive LSP position after lastLine.
// Only the document's final line needs a UTF-16 measurement. A final line
// using long-line mode is excluded as the editor cannot annotate it.
func (v *View) InlayHintRequestEnd(lastLine int) (line, utf16Column int) {
	if lastLine+1 < v.text.LineCount() {
		return lastLine + 1, 0
	}
	start, end := v.text.LineStart(lastLine), v.text.LineEnd(lastLine)
	if end-start > longLine {
		return lastLine, 0
	}
	return lastLine, v.utf16Units(start, end)
}

// InlayHintAt reports the ID and window rectangle of an interactive hint.
func (v *View) InlayHintAt(x, y float32) (int, gfx.Rect, bool) {
	if !v.painted || !v.HasInlayHints() || x < v.textLeft-textPad || x >= v.textRight || y < v.area.Y || y >= v.area.Y+v.area.Height {
		return 0, gfx.Rect{}, false
	}
	rowIndex := int((y - v.area.Y + v.scroll) / v.lineH)
	if rowIndex < 0 || rowIndex >= v.rowCount() {
		return 0, gfx.Rect{}, false
	}
	line, sub := v.rowLine(rowIndex)
	hints := v.lineInlayHints(line)
	if len(hints) == 0 {
		return 0, gfx.Rect{}, false
	}
	l := v.ref(line)
	rows := v.rowsOf(l)
	if sub < 0 || sub >= len(rows) {
		return 0, gfx.Rect{}, false
	}
	row := rows[sub]
	start := v.textLeft - v.scrollX
	y0 := v.area.Y + float32(rowIndex)*v.lineH - v.scroll
	composeRow, composeAt, composeCells := v.compositionRoom()
	for _, hint := range hints {
		if !hint.interactive || hint.byteCol < row.at || sub+1 < len(rows) && hint.byteCol >= rows[sub+1].at {
			continue
		}
		cell := hint.cell
		if composeCells > 0 && v.text.LineOf(v.caret) == line && sub == composeRow && cell >= composeAt {
			cell += composeCells
		}
		x0 := start + float32(cell-row.cells)*v.cellW
		width := float32(hint.cells) * v.cellW
		if x >= x0 && x < x0+width {
			return hint.id, gfx.Rect{X: x0, Y: y0, Width: width, Height: v.lineH}, true
		}
	}
	return 0, gfx.Rect{}, false
}

func cellsOfWithHints(line string, hints []preparedInlayHint, col int) int {
	col = min(max(col, 0), len(line))
	i := sort.Search(len(hints), func(i int) bool { return hints[i].byteCol > col })
	if i == 0 {
		return cellsOf(line, col)
	}
	hint := &hints[i-1]
	return inlayCells(line[hint.byteCol:col], hint.cell+hint.cells)
}

func columnInWithHints(line string, hints []preparedInlayHint, from, to, startCells int, cells float32) int {
	for _, hint := range hints {
		if hint.byteCol < from || hint.cell < startCells {
			continue
		}
		if hint.byteCol >= to {
			break
		}
		if cells < float32(hint.cell) {
			return columnIn(line, from, hint.byteCol, startCells, cells)
		}
		if cells < float32(hint.cell+hint.cells) {
			return hint.byteCol
		}
		from, startCells = hint.byteCol, hint.cell+hint.cells
	}
	return columnIn(line, from, to, startCells, cells)
}

// A hint and the following character share one byte anchor. Keep them on the
// same row even if the virtual label itself is wider than the viewport.
func wrapLineWithHints(dst []wrapRow, text string, hints []preparedInlayHint, cols int) []wrapRow {
	w := wrapper{rows: append(dst, wrapRow{}), cols: cols, prev: -1}
	at := 0
	for i := 0; i < len(hints); {
		hintAt := hints[i].byteCol
		w.feed(text[at:hintAt], at)
		width := 0
		for i < len(hints) && hints[i].byteCol == hintAt {
			width += hints[i].cells
			i++
		}
		next, size := utf8.DecodeRuneInString(text[hintAt:])
		if size > 0 {
			width += runeCells(next, w.cells+width)
		}
		if w.cells > w.start {
			pos := wrapRow{at: hintAt, cells: w.cells}
			if w.cells+width-w.start > cols {
				w.rows = append(w.rows, pos)
				w.start, w.brk = w.cells, wrapRow{}
			} else if pos.at > 0 {
				w.brk = pos
			}
		}
		w.cells += width
		w.prev = next
		at = hintAt + size
	}
	w.feed(text[at:], at)
	return w.rows
}

func (v *View) paintSingleHint(canvas *gfx.Canvas, h *preparedInlayHint, shift int, y float32, look Look) {
	tint := look.Foreground
	pillBg, pillBorder := tint, tint
	pillBg.Alpha, pillBorder.Alpha = 0.07, 0.13
	fg := look.Subtle
	fg.Alpha = 1

	textX := v.textLeft + float32(h.cell+h.padLeft-shift)*v.cellW - v.scrollX
	textWidth := float32(h.textCells) * v.cellW
	height := max(min(v.cellH+2, v.lineH-2), 1)
	top := y + (v.lineH-height)/2
	pill := gfx.Rect{X: textX - 2, Y: top, Width: textWidth + 4, Height: height}
	canvas.Fill(pill, pillBg)
	canvas.Fill(gfx.Rect{X: pill.X, Y: pill.Y, Width: pill.Width, Height: 1}, pillBorder)
	canvas.Fill(gfx.Rect{X: pill.X, Y: pill.Y + pill.Height - 1, Width: pill.Width, Height: 1}, pillBorder)

	runs := v.inlayRuns[:len(h.runs)]
	copy(runs, h.runs)
	for i := range runs {
		runs[i].Color = fg
	}
	style := gfx.TextStyle{Size: max(v.font.Size-1, 9), Color: fg, MonoFace: v.font.Face}
	rect := gfx.Rect{X: textX, Y: y + (v.lineH-v.cellH)/2, Width: float32(math.Ceil(float64(textWidth))) + 1, Height: v.cellH}
	canvas.LabelRuns(h.label, rect, style, v.cellW, runs)
}

func (v *View) paintRowWithHints(canvas *gfx.Canvas, text string, row wrapRow, end int, lastRow bool, hints []preparedInlayHint, look Look, from, to, shift int, y float32) {
	if from >= to {
		return
	}
	for i := range hints {
		hint := &hints[i]
		if hint.byteCol < row.at {
			continue
		}
		if hint.byteCol > end || hint.byteCol == end && !lastRow {
			break
		}
		v.paintRow(canvas, text[:hint.byteCol], 0, row, from, to, shift, y)
		if hint.cell+hint.cells > from && hint.cell < to {
			v.paintSingleHint(canvas, hint, shift, y, look)
		}
		row = wrapRow{at: hint.byteCol, cells: hint.cell + hint.cells}
	}
	v.paintRow(canvas, text[:end], 0, row, from, to, shift, y)
}
