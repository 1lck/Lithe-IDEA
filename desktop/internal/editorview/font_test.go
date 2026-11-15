package editorview

import (
	"fmt"
	"math"
	"slices"
	"strings"
	"testing"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// fontTestText is lines numbered lines, the first of them 600 columns long so the view has
// something to scroll sideways along.
func fontTestText(lines int) string {
	var text strings.Builder
	text.WriteString(strings.Repeat("0123456789", 60) + "\n")
	for i := 1; i < lines; i++ {
		fmt.Fprintf(&text, "line %d\n", i+1)
	}
	return text.String()
}

// paintAgain paints v into canvas, which it empties first as the window does for every frame.
func paintAgain(v *View, canvas *gfx.Canvas, area gfx.Rect) {
	canvas.Reset()
	v.Paint(canvas, area, Look{})
}

func TestDefaultFont(t *testing.T) {
	want := Font{Face: gfx.MonoSystem, Size: 13, LineSpacing: 1.4}
	if got := DefaultFont(); got != want {
		t.Fatalf("DefaultFont() = %+v, want %+v", got, want)
	}
	v := newTestView(t, "x")
	if got := v.Font(); got != want {
		t.Fatalf("a new view's font = %+v, want %+v", got, want)
	}
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})
	cellW, cellH := canvas.MonoCellSize(13, gfx.MonoSystem)
	if v.cellW != cellW || v.cellH != cellH {
		t.Fatalf("cell = %v x %v, want %v x %v, the system face at 13 points", v.cellW, v.cellH, cellW, cellH)
	}
	if lineH := float32(math.Round(float64(cellH * 1.4))); v.lineH != lineH {
		t.Fatalf("lineH = %v, want %v, 1.4 cells", v.lineH, lineH)
	}
}

// A size or a spacing of zero or less, or one that is not a number, is the default, so the
// window can leave them out of its settings.
func TestSetFontFillsInTheDefaults(t *testing.T) {
	v := newTestView(t, "x")
	for _, f := range []Font{
		{},
		{Size: -1, LineSpacing: -2},
		{Size: float32(math.NaN()), LineSpacing: float32(math.NaN())},
	} {
		v.SetFont(Font{Size: 20, LineSpacing: 1.1})
		v.SetFont(f)
		if got := v.Font(); got != DefaultFont() {
			t.Fatalf("SetFont(%+v) left the font %+v, want the default %+v", f, got, DefaultFont())
		}
	}
	v.SetFont(Font{Face: gfx.MonoClassic, Ligatures: true})
	want := Font{Face: gfx.MonoClassic, Size: 13, LineSpacing: 1.4, Ligatures: true}
	if got := v.Font(); got != want {
		t.Fatalf("font = %+v, want %+v: the face and the ligatures are kept, the size and spacing default", got, want)
	}
}

// The window sets the font on every frame, so setting the font the view has changes nothing and
// allocates nothing, and the next paint draws what the one before drew.
func TestSetFontToTheCurrentFontChangesNothing(t *testing.T) {
	v := newTestView(t, fontTestText(300))
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 400}
	current := Font{Size: 16, LineSpacing: 1.5}
	v.SetFont(current)
	v.Paint(canvas, area, Look{})
	v.scroll, v.scrollX = 40.5*v.lineH, 12.25*v.cellW
	paintAgain(v, canvas, area)
	scroll, scrollX, cellW, cellH, lineH := v.scroll, v.scrollX, v.cellW, v.cellH, v.lineH

	// The same font once its defaults are filled in is the same font.
	spelled := Font{Face: gfx.MonoSystem, Size: 16, LineSpacing: 1.5}
	if allocs := testing.AllocsPerRun(20, func() { v.SetFont(current); v.SetFont(spelled) }); allocs != 0 {
		t.Fatalf("setting the current font allocates %v times, want none", allocs)
	}
	if got := v.Font(); got != current {
		t.Fatalf("font = %+v, want %+v", got, current)
	}
	paintAgain(v, canvas, area)
	if v.scroll != scroll || v.scrollX != scrollX || v.cellW != cellW || v.cellH != cellH || v.lineH != lineH {
		t.Fatalf("after painting, scroll %v,%v cell %vx%v lineH %v, want %v,%v %vx%v %v",
			v.scroll, v.scrollX, v.cellW, v.cellH, v.lineH, scroll, scrollX, cellW, cellH, lineH)
	}

	fresh := newTestView(t, "x")
	fresh.SetFont(Font{})
	if fresh.Font() != DefaultFont() {
		t.Fatalf("an empty font on a new view left %+v, want the default", fresh.Font())
	}
}

// A larger font makes the cell and the line larger from the next paint on, and a larger spacing
// alone makes the line taller but not the cell.
func TestLargerFontMakesTheCellAndTheLineLarger(t *testing.T) {
	v := newTestView(t, fontTestText(300))
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 400}
	v.Paint(canvas, area, Look{})
	cellW, cellH, lineH, textLeft, maxScroll := v.cellW, v.cellH, v.lineH, v.textLeft, v.maxScroll()

	v.SetFont(Font{Size: 26})
	if v.cellW != cellW || v.cellH != cellH || v.lineH != lineH {
		t.Fatal("setting the font changed the geometry before the paint")
	}
	paintAgain(v, canvas, area)
	wantW, wantH := canvas.MonoCellSize(26, gfx.MonoSystem)
	if v.cellW != wantW || v.cellH != wantH || v.cellW <= cellW || v.cellH <= cellH {
		t.Fatalf("cell = %vx%v, want %vx%v, larger than %vx%v", v.cellW, v.cellH, wantW, wantH, cellW, cellH)
	}
	if want := float32(math.Round(float64(wantH * 1.4))); v.lineH != want || v.lineH <= lineH {
		t.Fatalf("lineH = %v, want %v, taller than %v", v.lineH, want, lineH)
	}
	if v.textLeft < textLeft || v.maxScroll() <= maxScroll {
		t.Fatalf("textLeft %v and scroll range %v, want them no less than %v and more than %v", v.textLeft, v.maxScroll(), textLeft, maxScroll)
	}

	v.SetFont(Font{Size: 26, LineSpacing: 2})
	paintAgain(v, canvas, area)
	if v.cellW != wantW || v.cellH != wantH {
		t.Fatalf("a new spacing changed the cell to %vx%v, want %vx%v", v.cellW, v.cellH, wantW, wantH)
	}
	if want := float32(math.Round(float64(wantH * 2))); v.lineH != want {
		t.Fatalf("lineH = %v, want %v, two cells", v.lineH, want)
	}

	// A spacing that leaves no room for a row never divides the scroll by nothing.
	v.SetFont(Font{Size: 13, LineSpacing: 0.001})
	paintAgain(v, canvas, area)
	if v.lineH < 1 {
		t.Fatalf("lineH = %v, want at least 1", v.lineH)
	}
}

// The face and the size reach everything the view draws: the text, the line numbers, the
// annotations after a line, and the platform's composition at the caret.
func TestFontReachesEveryLabelAndTheInput(t *testing.T) {
	v := newTestView(t, "alpha\nbeta")
	v.SetLineAnnotations([]LineAnnotation{{Line: 0, Text: "note"}})
	v.SetFont(Font{Face: gfx.MonoClassic, Size: 21})
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})

	labels := lineLabels(canvas, v)
	var values []string
	for _, label := range labels {
		values = append(values, label.Value)
	}
	slices.Sort(values)
	if strings.Join(values, ",") != "alpha,beta,note" {
		t.Fatalf("text labels = %q, want the two lines and the annotation", values)
	}
	numbers := numberLabels(canvas, v)
	if len(numbers) != 2 {
		t.Fatalf("drew %d line numbers, want 2", len(numbers))
	}
	for _, label := range append(labels, numbers...) {
		if style := label.Style; !style.Mono || style.Size != 21 || style.MonoFace != gfx.MonoClassic {
			t.Fatalf("label %q is drawn in %+v, want the classic mono face at 21 points", label.Value, style)
		}
	}
	input := v.TextInput(app.TextInputContext{ID: v.cfg.HitID})
	if input == nil || input.FontSize != 21 || input.MonoFace != gfx.MonoClassic {
		t.Fatalf("text input = %+v, want the classic mono face at 21 points", input)
	}
}

// A change of font keeps the reader's place: the line that was at the top, as far out of the
// view as it was, stays at the top, and the column at the left edge stays there.
func TestFontChangeKeepsTheFirstVisibleLineAndColumn(t *testing.T) {
	for _, c := range []struct {
		name string
		font Font
	}{
		{"larger", Font{Size: 26}},
		{"smaller", Font{Size: 9}},
		{"more spacing", Font{Size: 13, LineSpacing: 2.2}},
		{"another face", Font{Face: gfx.MonoClassic, Size: 18}},
	} {
		t.Run(c.name, func(t *testing.T) {
			v := newTestView(t, fontTestText(500))
			canvas := new(gfx.Canvas)
			area := gfx.Rect{X: 20, Y: 30, Width: 900, Height: 400}
			v.Paint(canvas, area, Look{})
			cellW, lineH := v.cellW, v.lineH
			// Half a row of line 101 is out of the view, and half a cell of column 20.
			v.scroll, v.scrollX = 100.5*v.lineH, 20.5*v.cellW
			paintAgain(v, canvas, area)
			if numbers := numberLabels(canvas, v); len(numbers) == 0 || numbers[0].Value != "101" {
				t.Fatalf("before the change the first number is %v, want 101", numbers)
			}

			v.SetFont(c.font)
			paintAgain(v, canvas, area)
			if v.cellW == cellW && v.lineH == lineH {
				t.Fatal("the font changed neither the cell nor the line")
			}
			if row := v.scroll / v.lineH; math.Abs(float64(row-100.5)) > 0.01 {
				t.Fatalf("scroll is %v rows, want 100.5", row)
			}
			if column := v.scrollX / v.cellW; math.Abs(float64(column-20.5)) > 0.01 {
				t.Fatalf("scrollX is %v columns, want 20.5", column)
			}
			if numbers := numberLabels(canvas, v); len(numbers) == 0 || numbers[0].Value != "101" {
				t.Fatalf("after the change the first number is %v, want 101", numbers)
			}
		})
	}
}

// A wrapped text breaks into other rows with another cell, as it does with another width, and
// the line at the top stays at the top.
func TestFontChangeKeepsTheFirstVisibleLineOfAWrappedText(t *testing.T) {
	var text strings.Builder
	for i := range 300 {
		fmt.Fprintf(&text, "line %d %s\n", i+1, strings.Repeat("word ", 30))
	}
	v := newTestView(t, text.String())
	v.SetWrap(true)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 700, Height: 400}
	v.Paint(canvas, area, Look{})
	cols := v.wrapCols
	if cols <= 0 || v.lineRow(1) < 2 {
		t.Fatalf("wrapped at %d columns with line 1 at row %d, want rows to wrap", cols, v.lineRow(1))
	}
	v.scroll = float32(v.lineRow(100)) * v.lineH
	paintAgain(v, canvas, area)
	if numbers := numberLabels(canvas, v); len(numbers) == 0 || numbers[0].Value != "101" {
		t.Fatalf("before the change the first number is %v, want 101", numbers)
	}

	v.SetFont(Font{Size: 20})
	paintAgain(v, canvas, area)
	if v.wrapCols <= 0 || v.wrapCols >= cols {
		t.Fatalf("wrapped at %d columns, want fewer than the %d of the smaller font", v.wrapCols, cols)
	}
	if line, sub := v.rowLine(int(v.scroll / v.lineH)); line != 100 || sub != 0 {
		t.Fatalf("the top row is row %d of line %d, want the first row of line 100", sub, line)
	}
	if numbers := numberLabels(canvas, v); len(numbers) == 0 || numbers[0].Value != "101" {
		t.Fatalf("after the change the first number is %v, want 101", numbers)
	}

	// Only the spacing changes: the rows stay and the scroll follows the height of a row.
	cols = v.wrapCols
	v.SetFont(Font{Size: 20, LineSpacing: 2})
	paintAgain(v, canvas, area)
	if v.wrapCols != cols {
		t.Fatalf("wrapped at %d columns after a new spacing, want the same %d", v.wrapCols, cols)
	}
	if line, sub := v.rowLine(int(v.scroll / v.lineH)); line != 100 || sub != 0 {
		t.Fatalf("after a new spacing the top row is row %d of line %d, want the first row of line 100", sub, line)
	}
}

// Ligatures are asked of the runs of text that are ASCII and two cells or more, as Viva needs
// them to be, when the font has them on, and of no run otherwise. The line numbers never are.
func TestLigaturesAreAskedOfRunsOfAtLeastTwoCellsOfASCII(t *testing.T) {
	text := "ab->中cd\nx != y\n中x中\n" + strings.Repeat("l\n", 9) + "last"
	for _, on := range []bool{false, true} {
		t.Run(fmt.Sprintf("ligatures %v", on), func(t *testing.T) {
			v := newTestView(t, text)
			v.SetFont(Font{Ligatures: on})
			canvas := new(gfx.Canvas)
			v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})

			labels := lineLabels(canvas, v)
			if len(labels) != 13 {
				t.Fatalf("drew %d lines, want 13", len(labels))
			}
			for _, label := range labels {
				offset := 0
				for _, run := range canvas.TextRuns(label) {
					value := label.Value[offset : offset+int(run.Bytes)]
					offset += int(run.Bytes)
					ascii := true
					for i := range len(value) {
						ascii = ascii && value[i] < 0x80
					}
					if want := on && ascii && run.Cells >= 2; run.Ligatures != want {
						t.Fatalf("run %q of %q, %d cells: Ligatures = %v, want %v", value, label.Value, run.Cells, run.Ligatures, want)
					}
				}
			}
			// The shapes the rule is for, spelled out.
			for i, want := range [][]bool{{on, false, on}, {on}, {false, false, false}} {
				runs := canvas.TextRuns(labels[i])
				if len(runs) != len(want) {
					t.Fatalf("line %d has %d runs, want %d", i+1, len(runs), len(want))
				}
				for k, run := range runs {
					if run.Ligatures != want[k] {
						t.Fatalf("line %d run %d: Ligatures = %v, want %v", i+1, k, run.Ligatures, want[k])
					}
				}
			}
			numbers := numberLabels(canvas, v)
			if len(numbers) != 13 || len(numbers[12].Value) != 2 {
				t.Fatalf("drew %d numbers, the last %q, want 13 of them, ending with a two-digit one", len(numbers), numbers[len(numbers)-1].Value)
			}
			for _, number := range numbers {
				for _, run := range canvas.TextRuns(number) {
					if run.Ligatures {
						t.Fatalf("line number %q asks for ligatures", number.Value)
					}
				}
			}
		})
	}
}

// A paint that is given the font on every frame, as the window does, still allocates nothing,
// with ligatures asked of its runs.
func TestRepaintWithAFontAllocatesNothing(t *testing.T) {
	var text strings.Builder
	for i := range 3000 {
		fmt.Fprintf(&text, "\tline %d -> of 中文 and é != x\n", i)
	}
	v := newTestView(t, text.String())
	font := Font{Face: gfx.MonoClassic, Size: 15, LineSpacing: 1.6, Ligatures: true}
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 600}
	paint := func() {
		canvas.Reset()
		v.SetFont(font)
		v.Paint(canvas, area, Look{})
	}
	paint()
	v.scroll = 1000 * v.lineH
	paint()
	ligated := false
	for _, label := range lineLabels(canvas, v) {
		for _, run := range canvas.TextRuns(label) {
			ligated = ligated || run.Ligatures
		}
	}
	if !ligated {
		t.Fatal("no run asked for ligatures")
	}
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a repaint allocates %v times, want none", allocs)
	}
}
