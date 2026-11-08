package editorview

import (
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/vivaui/viva/ui"
)

// paintWrapped paints v with soft wrapping in area and returns the canvas and the columns the
// text wrapped at.
func paintWrapped(t *testing.T, v *View, area ui.Rect) (*ui.Canvas, int) {
	t.Helper()
	v.SetWrap(true)
	canvas := new(ui.Canvas)
	v.Paint(canvas, area, Look{})
	if v.wrapCols <= 0 {
		t.Fatalf("the view wrapped at %d columns", v.wrapCols)
	}
	return canvas, v.wrapCols
}

func TestWrapLineBreaksBetweenWordsAndWideCharacters(t *testing.T) {
	for _, c := range []struct {
		text string
		cols int
		want []wrapRow
	}{
		{"a b", 10, []wrapRow{{0, 0}}},
		{"hello world", 8, []wrapRow{{0, 0}, {6, 6}}},
		{"abcdefghij", 4, []wrapRow{{0, 0}, {4, 4}, {8, 8}}},
		// A word longer than a row breaks inside it, after the word before it moved down.
		{"ab cdefghijk", 5, []wrapRow{{0, 0}, {3, 3}, {8, 8}}},
		// Chinese breaks between any two characters.
		{"中文中文中", 5, []wrapRow{{0, 0}, {6, 4}, {12, 8}}},
		// A tab keeps the stops of the whole line, and a row may break after it.
		{"\tab\tcd", 5, []wrapRow{{0, 0}, {1, 4}, {4, 8}}},
		// A character wider than the row takes a row of its own.
		{"中a", 1, []wrapRow{{0, 0}, {3, 2}}},
		{"x\r", 1, []wrapRow{{0, 0}}},
	} {
		if got := wrapLine(nil, c.text, c.cols); !slices.Equal(got, c.want) {
			t.Errorf("wrapLine(%q, %d) = %v, want %v", c.text, c.cols, got, c.want)
		}
	}
}

// The line numbers are clipped to the view and drawn on the cell grid with their right edges
// on one column, so a number scrolled half out of the view never shows over the tab bar above
// it and the digits of 9, 10 and 100 stay in columns.
func TestLineNumbersAreClippedAndRightAlignedOnTheGrid(t *testing.T) {
	var text strings.Builder
	for i := range 120 {
		fmt.Fprintf(&text, "line %d\n", i+1)
	}
	v := newTestView(t, text.String())
	canvas := new(ui.Canvas)
	area := ui.Rect{X: 40, Y: 30, Width: 600, Height: 400}
	v.Paint(canvas, area, Look{})
	v.scroll = 92.5 * v.lineH
	canvas.Reset()
	v.Paint(canvas, area, Look{})

	numbers := numberLabels(canvas, v)
	if len(numbers) == 0 {
		t.Fatal("no line numbers were drawn")
	}
	if first := numbers[0]; first.Value != "93" || first.Bounds.Y >= area.Y {
		t.Fatalf("first number %q at y %v, want 93 starting above the view at %v", first.Value, first.Bounds.Y, area.Y)
	}
	right := float32(math.NaN())
	for _, n := range numbers {
		if n.ClipOf.Y < area.Y || n.ClipOf.Y+n.ClipOf.Height > area.Y+area.Height {
			t.Fatalf("number %q is clipped to %+v, which leaves the view %+v", n.Value, n.ClipOf, area)
		}
		if n.RunCount != 1 || n.CellWidth != v.cellW {
			t.Fatalf("number %q has %d runs at cell width %v, want one run on the %v grid", n.Value, n.RunCount, n.CellWidth, v.cellW)
		}
		edge := n.Bounds.X + float32(len(n.Value))*v.cellW
		if math.IsNaN(float64(right)) {
			right = edge
		}
		if math.Abs(float64(edge-right)) > 0.01 {
			t.Fatalf("number %q ends at %v, want %v as the others", n.Value, edge, right)
		}
	}
	values := make([]string, 0, len(numbers))
	for _, n := range numbers {
		values = append(values, n.Value)
	}
	if !slices.Contains(values, "99") || !slices.Contains(values, "100") {
		t.Fatalf("numbers = %v, want 99 and 100 among them", values)
	}
}

// A wrapped line shows its number once, on its first row, and the lines after it move down by
// its rows.
func TestWrappedLineShowsItsNumberOnItsFirstRow(t *testing.T) {
	v := newTestView(t, "short\n"+strings.Repeat("x", 200)+"\nend")
	canvas, cols := paintWrapped(t, v, ui.Rect{Width: 400, Height: 600})
	rows := (200 + cols - 1) / cols
	if rows < 2 {
		t.Fatalf("200 columns wrapped at %d take %d rows, want several", cols, rows)
	}
	numbers := numberLabels(canvas, v)
	var got []string
	for _, n := range numbers {
		got = append(got, n.Value)
	}
	if !slices.Equal(got, []string{"1", "2", "3"}) {
		t.Fatalf("numbers = %v, want one for each line", got)
	}
	if want := float32(1+rows) * v.lineH; math.Abs(float64(numbers[2].Bounds.Y-(want+(v.lineH-v.cellH)/2))) > 0.01 {
		t.Fatalf("line 3's number is at %v, want it %d rows down", numbers[2].Bounds.Y, 1+rows)
	}
	labels := lineLabels(canvas, v)
	if len(labels) != 1+rows+1 {
		t.Fatalf("drew %d text labels, want %d: one for each row", len(labels), 1+rows+1)
	}
	for _, label := range labels {
		if math.Abs(float64(label.Bounds.X-v.textLeft)) > 0.01 {
			t.Fatalf("row %q starts at %v, want the text's left edge %v", label.Value, label.Bounds.X, v.textLeft)
		}
	}
	if v.rowCount() != rows+2 {
		t.Fatalf("rowCount = %d, want %d", v.rowCount(), rows+2)
	}
}

// Up and down step through a wrapped line row by row, and a click lands on the row under it.
func TestUpDownAndClicksGoByRows(t *testing.T) {
	v := newTestView(t, strings.Repeat("x", 100)+"\nend")
	_, cols := paintWrapped(t, v, ui.Rect{Width: 300, Height: 600})
	v.moveTo(3, false)
	v.press(ui.KeyDown, 0)
	if v.caret != cols+3 {
		t.Fatalf("down from column 3 went to %d, want %d on the next row", v.caret, cols+3)
	}
	if _, y := v.caretPoint(); math.Abs(float64(y-v.lineH)) > 0.01 {
		t.Fatalf("caret on the second row is at y %v, want %v", y, v.lineH)
	}
	v.press(ui.KeyUp, 0)
	if v.caret != 3 {
		t.Fatalf("up went back to %d, want 3", v.caret)
	}
	for v.text.LineOf(v.caret) == 0 {
		v.press(ui.KeyDown, 0)
	}
	if line, col := v.Caret(); line != 1 || col != 3 {
		t.Fatalf("down past the wrapped line went to line %d column %d, want line 1 column 3", line, col)
	}

	if got := v.offsetAt(v.textLeft+2.2*v.cellW, v.area.Y+1.5*v.lineH); got != cols+2 {
		t.Fatalf("a click on the second row at column 2 = %d, want %d", got, cols+2)
	}
	if got := v.offsetAt(v.textLeft+float32(cols+5)*v.cellW, v.area.Y+0.5*v.lineH); got != cols-1 {
		t.Fatalf("a click past the end of the first row = %d, want %d, before its last character", got, cols-1)
	}
}

// Edits keep the rows of every line what laying out the whole text again gives.
func TestEditsKeepTheRowsOfEveryLine(t *testing.T) {
	v := newTestView(t, strings.Repeat("word ", 30)+"\nshort\n"+strings.Repeat("中文", 40)+"\n\tend")
	_, cols := paintWrapped(t, v, ui.Rect{Width: 300, Height: 600})
	check := func(step string) {
		t.Helper()
		v.ensureRows()
		row := 0
		for line := range v.text.LineCount() {
			text := v.text.Line(line)
			if got := v.lineRow(line); got != row {
				t.Fatalf("after %s: line %d starts at row %d, want %d", step, line, got, row)
			}
			row += len(wrapLine(nil, text, cols))
		}
		if got := v.rowCount(); got != row {
			t.Fatalf("after %s: rowCount = %d, want %d", step, got, row)
		}
	}
	check("painting")
	v.moveTo(10, false)
	v.typeText(strings.Repeat("long ", 20))
	check("typing")
	v.insert("\n\nnew "+strings.Repeat("y", 90)+"\n", editOther)
	check("inserting lines")
	v.anchor, v.caret = 5, v.text.LineStart(3)+4
	v.insert("", editOther)
	check("deleting across lines")
	v.Undo()
	check("undo")
	v.Redo()
	check("redo")
}

// Turning wrapping on and off keeps the line at the top of the view at the top, as far out of
// the view as it was.
func TestTogglingWrapKeepsTheTopLine(t *testing.T) {
	var text strings.Builder
	for i := range 200 {
		text.WriteString(strconv.Itoa(i) + " " + strings.Repeat("abc ", 30) + "\n")
	}
	v := newTestView(t, text.String())
	canvas := new(ui.Canvas)
	area := ui.Rect{Width: 300, Height: 400}
	v.Paint(canvas, area, Look{})
	part := v.lineH / 4
	v.scroll = 50*v.lineH + part
	v.Paint(canvas, area, Look{})

	v.SetWrap(true)
	v.Paint(canvas, area, Look{})
	if line, sub := v.rowLine(int(v.scroll / v.lineH)); line != 50 || sub != 0 {
		t.Fatalf("after wrapping the top is line %d row %d, want line 50", line, sub)
	}
	if got := v.scroll - float32(v.lineRow(50))*v.lineH; math.Abs(float64(got-part)) > 0.01 {
		t.Fatalf("after wrapping line 50 is %v out of the view, want %v", got, part)
	}
	if v.scrollX != 0 {
		t.Fatalf("a wrapped view is scrolled sideways by %v", v.scrollX)
	}
	v.SetWrap(false)
	v.Paint(canvas, area, Look{})
	if want := 50*v.lineH + part; math.Abs(float64(v.scroll-want)) > 0.01 {
		t.Fatalf("after unwrapping the view is scrolled to %v, want %v", v.scroll, want)
	}
}
