package editorview

import (
	"math"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/vivaui/viva/gfx"
)

// longText is a line of at least size bytes, longer than longLine, of tabs, wide and accented
// characters, control characters and bytes that are not UTF-8, ending in a carriage return, so
// its characters lie across the rope's leaves and the stops fall on every kind of character.
func longText(size int) string {
	pieces := []string{"ab", "\t", "中文", "é", "\x01", "\xff", "x́", "  ", "z", "\xe4\xb8", "ok"}
	var b strings.Builder
	for i := 0; b.Len() < size; i++ {
		b.WriteString(pieces[i%len(pieces)])
		if i%7 == 0 {
			b.WriteString(strconv.Itoa(i))
		}
	}
	b.WriteString("\r")
	return b.String()
}

// boundaries is every step-th place in line where a character starts, as range reads it, and
// the last few and the end of the line.
func boundaries(line string, step int) []int {
	var cols []int
	k := 0
	for i := range line {
		if k%step == 0 || i >= len(line)-12 {
			cols = append(cols, i)
		}
		k++
	}
	return append(cols, len(line))
}

// wholeCells is cellsOf(line, col) for every col where a character of line starts and for its
// end, counted in one pass instead of from the line's start for each column; other places are
// 0. Its first columns are checked against cellsOf itself.
func wholeCells(t *testing.T, line string) []int {
	t.Helper()
	cells := make([]int, len(line)+1)
	sum := 0
	for i, r := range line {
		cells[i] = sum
		sum += runeCells(r, sum)
	}
	cells[len(line)] = sum
	for _, col := range boundaries(line[:min(len(line), 3*stopBytes)], 97) {
		if cells[col] != cellsOf(line, col) {
			t.Fatalf("wholeCells at %d = %d, want %d as cellsOf counts", col, cells[col], cellsOf(line, col))
		}
	}
	return cells
}

// longRef is line 0 of v, which must be long.
func longRef(t *testing.T, v *View) lineRef {
	t.Helper()
	l := v.ref(0)
	if !l.long {
		t.Fatalf("line 0 is %d bytes, not longer than %d", l.size, longLine)
	}
	return l
}

// A long line is read a part at a time from stops along it, and every column it gives is the
// one counting the whole line gives, whichever order the columns are asked for in.
func TestLongLineCellsMatchTheWholeLine(t *testing.T) {
	line := longText(3 * longLine)
	want := wholeCells(t, line)
	cols := boundaries(line, 37)
	orders := map[string][]int{"ascending": cols, "descending": slices.Clone(cols)}
	slices.Reverse(orders["descending"])
	scattered := make([]int, 0, len(cols))
	for i := range cols {
		scattered = append(scattered, cols[(i*7919)%len(cols)])
	}
	orders["scattered"] = scattered
	for name, order := range orders {
		v := newTestView(t, line)
		l := longRef(t, v)
		for _, col := range order {
			if got := v.cellsAt(l, col); got != want[col] {
				t.Fatalf("%s: cellsAt(%d) = %d, want %d", name, col, got, want[col])
			}
		}
	}
}

// The column under a point of a long line, as a click or a move up or down finds it, is the one
// columnIn finds in the whole line, on the whole line and on a part of it; the carriage return
// that ends it is a column, not the end.
func TestLongLineColumnUnderAPointMatchesTheWholeLine(t *testing.T) {
	line := longText(2 * longLine)
	want := wholeCells(t, line)
	v := newTestView(t, line)
	l := longRef(t, v)
	// columnIn reads the line from its start, so the columns it checks are far apart.
	for _, col := range boundaries(line, 701) {
		cells := float32(want[col])
		for _, c := range []float32{cells - 0.5, cells, cells + 0.3, cells + 0.5, cells + 0.7, cells + 3} {
			if got, want := v.columnFrom(l, 0, l.size, 0, c), columnIn(line, 0, len(line), 0, c); got != want {
				t.Fatalf("columnFrom at %v cells = %d, want %d", c, got, want)
			}
		}
	}
	for _, c := range []float32{-3, 1e12} {
		if got, want := v.columnFrom(l, 0, l.size, 0, c), columnIn(line, 0, len(line), 0, c); got != want {
			t.Fatalf("columnFrom at %v cells = %d, want %d", c, got, want)
		}
	}
	cols := boundaries(line, 53)
	for i := 0; i+3 < len(cols); i += 5 {
		from, to := cols[i], cols[i+3]
		start := want[from]
		for _, c := range []float32{float32(start) - 1, float32(start) + 0.6, float32(want[to]) + 1} {
			if got, want := v.columnFrom(l, from, to, start, c), columnIn(line, from, to, start, c); got != want {
				t.Fatalf("columnFrom(%d, %d) at %v cells = %d, want %d", from, to, c, got, want)
			}
		}
	}
	for _, end := range cols[1:] {
		from := max(end-40, 0)
		_, size := utf8.DecodeLastRuneInString(line[from:end])
		if got := v.lastRuneSize(l, from, end); got != size {
			t.Fatalf("lastRuneSize(%d, %d) = %d, want %d", from, end, got, size)
		}
	}
}

// sameLabels fails t unless the labels got, of a paint, are the labels want, of painting the
// whole line: the same text in the same place, in the same runs.
func sameLabels(t *testing.T, at string, gotCanvas *gfx.Canvas, got []gfx.Text, wantCanvas *gfx.Canvas, want []gfx.Text) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: drew %d labels, want %d", at, len(got), len(want))
	}
	for i := range want {
		g, w := got[i], want[i]
		if g.Value != w.Value || g.Bounds != w.Bounds {
			t.Fatalf("%s: label %d is %.20q at %+v, want %.20q at %+v", at, i, g.Value, g.Bounds, w.Value, w.Bounds)
		}
		if gr, wr := gotCanvas.TextRuns(g), wantCanvas.TextRuns(w); !slices.Equal(gr, wr) {
			t.Fatalf("%s: label %d runs = %+v, want %+v", at, i, gr, wr)
		}
	}
}

// drawnLabels is the labels a canvas holds that show text.
func drawnLabels(canvas *gfx.Canvas) []gfx.Text {
	var labels []gfx.Text
	for _, text := range canvas.Texts() {
		if text.RunCount > 0 {
			labels = append(labels, text)
		}
	}
	return labels
}

// Painting a long line, scrolled anywhere along it, draws the labels painting the whole line
// draws, and reads it only as far as the columns shown.
func TestLongLinePaintMatchesTheWholeLine(t *testing.T) {
	line := longText(3 * longLine)
	v := newTestView(t, line)
	canvas, whole := new(gfx.Canvas), new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 300}
	v.Paint(canvas, area, Look{})
	if s := v.stops[0]; s != nil && s.done {
		t.Fatal("painting the start of the line read all of it")
	}
	cellsEnd := cellsOf(line, len(line))
	for _, column := range []int{0, 1, 999, 70_001, cellsEnd / 2, cellsEnd - 60, cellsEnd - 3, cellsEnd + 50} {
		canvas.Reset()
		v.scrollX = float32(column) * v.cellW
		v.Paint(canvas, area, Look{})
		at := "scrolled to column " + strconv.Itoa(column)
		from, to := v.visibleCells()
		whole.Reset()
		v.paintRow(whole, line, 0, wrapRow{}, from, to, 0, area.Y-v.scroll)
		sameLabels(t, at, canvas, lineLabels(canvas, v), whole, drawnLabels(whole))
	}
}

// A wrapped long line breaks into the rows wrapLine breaks the whole line into, and each row
// paints the labels painting it from the whole line does.
func TestWrappedLongLineMatchesTheWholeLine(t *testing.T) {
	line := longText(2 * longLine)
	v := newTestView(t, line)
	v.SetWrap(true)
	canvas, whole := new(gfx.Canvas), new(gfx.Canvas)
	area := gfx.Rect{Width: 700, Height: 300}
	v.Paint(canvas, area, Look{})
	if !v.wrapping() {
		t.Fatal("the view does not wrap")
	}
	l := longRef(t, v)
	rows := v.rowsOf(l)
	if want := wrapLine(nil, line, v.wrapCols); !slices.Equal(rows, want) {
		t.Fatalf("the line breaks into %d rows, want %d as wrapLine breaks it", len(rows), len(want))
	}
	for _, first := range []int{0, 17, len(rows) / 2, len(rows) - 3} {
		canvas.Reset()
		v.scroll = float32(first) * v.lineH
		v.Paint(canvas, area, Look{})
		whole.Reset()
		for k, row := range rows {
			y := area.Y + float32(k)*v.lineH - v.scroll
			if y+v.lineH <= area.Y || y >= area.Y+area.Height {
				continue
			}
			to := math.MaxInt
			if k+1 < len(rows) {
				to = rows[k+1].cells
			}
			v.paintRow(whole, line, 0, row, row.cells, to, row.cells, y)
		}
		sameLabels(t, "from row "+strconv.Itoa(first), canvas, lineLabels(canvas, v), whole, drawnLabels(whole))
	}
}

// The minimap's bars of a long line, wrapped or not, are the ones of the whole line.
func TestLongLineMinimapBarsMatchTheWholeLine(t *testing.T) {
	line := longText(2 * longLine)
	for _, wrap := range []bool{false, true} {
		v := newTestView(t, line)
		v.SetWrap(wrap)
		v.Paint(new(gfx.Canvas), gfx.Rect{Width: 700, Height: 300}, Look{})
		const cols = 120
		l := longRef(t, v)
		rows := v.minimapRows(l)
		last := min(len(rows)-1, 40)
		v.mm.marks = v.mm.marks[:0]
		v.markRows(0, last, cols)
		got := slices.Clone(v.mm.marks)
		v.mm.marks = v.mm.marks[:0]
		v.mm.tokens = v.hl.Line(v.mm.tokens[:0], 0)
		for k := 0; k <= last; k++ {
			end := len(line)
			if k+1 < len(rows) {
				end = rows[k+1].at
			}
			v.markRow(line, 0, rows[k], end, int32(k), cols)
		}
		if !slices.Equal(got, v.mm.marks) {
			t.Fatalf("wrap %v: %d bars, want %d as the whole line gives", wrap, len(got), len(v.mm.marks))
		}
	}
}

// An edit keeps what the view read of a long line before the edit, and of long lines the edit
// did not touch, and every column after it is still the one counting the whole line gives:
// after typing into the line, deleting half a character, editing another line, breaking the
// line in two and undoing it all.
func TestLongLineStopsFollowEdits(t *testing.T) {
	line := longText(3 * longLine)
	text := line + "\nshort\n" + line
	v := newTestView(t, text)
	check := func(at string) {
		t.Helper()
		for n := range v.text.LineCount() {
			l := v.ref(n)
			if !l.long {
				continue
			}
			whole := v.text.Line(n)
			want := wholeCells(t, whole)
			for _, col := range boundaries(whole, 61) {
				if got := v.cellsAt(l, col); got != want[col] {
					t.Fatalf("%s: line %d cellsAt(%d) = %d, want %d", at, n, col, got, want[col])
				}
			}
		}
	}
	check("before any edit")
	mid := strings.Index(line[len(line)/2:], "中") + len(line)/2

	v.edit(mid, mid, "\t中x", editOther)
	if s := v.stops[0]; s == nil || len(s.stops) < 2 || s.stops[len(s.stops)-1].at+utf8.UTFMax > mid {
		t.Fatal("typing into the line dropped its stops before the edit, or kept ones after it")
	}
	if s := v.stops[2]; s == nil || !s.done {
		t.Fatal("typing into a line dropped the stops of another line the edit did not move")
	}
	check("after typing")

	v.edit(mid+1, mid+2, "", editOther)
	check("after deleting the first byte of a character")

	short := v.text.LineStart(1)
	v.edit(short, short+1, "S", editOther)
	if s := v.stops[0]; s == nil || !s.done {
		t.Fatal("editing another line dropped the stops of the long line before it")
	}
	check("after editing another line")

	v.edit(mid-7, mid-7, "\n", editOther)
	check("after breaking the line")

	for v.Undo() {
	}
	if got := v.text.String(); got != text {
		t.Fatalf("undoing every edit left %d bytes, want the %d of the text", len(got), len(text))
	}
	check("after undoing")
}

// Painting a long line again, unwrapped or wrapped, as the caret's blink does, allocates
// nothing: the parts it shows are kept.
func TestRepaintingALongLineAllocatesNothing(t *testing.T) {
	line := longText(1 << 20)
	for _, wrap := range []bool{false, true} {
		v := newTestView(t, line+"\nnext")
		v.SetWrap(wrap)
		canvas := new(gfx.Canvas)
		area := gfx.Rect{Width: 900, Height: 600}
		paint := func() {
			canvas.Reset()
			v.Paint(canvas, area, Look{})
		}
		paint()
		if wrap {
			v.scroll = 3000 * v.lineH
		} else {
			v.scrollX = 400_000 * v.cellW
		}
		paint()
		paint()
		if len(lineLabels(canvas, v)) == 0 {
			t.Fatalf("wrap %v: the paint drew no text", wrap)
		}
		if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
			t.Fatalf("wrap %v: a repaint allocates %v times, want none", wrap, allocs)
		}
	}
}
