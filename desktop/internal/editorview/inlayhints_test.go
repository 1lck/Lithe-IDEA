package editorview

import (
	"slices"
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

func prepareTestHints(t *testing.T, v *View, specs ...InlayHintSpec) PreparedInlayHints {
	t.Helper()
	prepared, err := PrepareInlayHints(t.Context(), v.TextSnapshot(), v.Revision(), specs)
	if err != nil {
		t.Fatal(err)
	}
	return prepared
}

func installTestHints(t *testing.T, v *View, specs ...InlayHintSpec) {
	t.Helper()
	if !v.SetPreparedInlayHints(prepareTestHints(t, v, specs...)) {
		t.Fatal("editor rejected hints for its current snapshot")
	}
}

func TestInlayHintOversizedAtWrapBoundaryIsPaintedAndHitOnce(t *testing.T) {
	v := newTestView(t, "abcde\r\nnext")
	canvas := new(gfx.Canvas)
	w, _ := canvas.MonoCellSize(DefaultFont().Size, DefaultFont().Face)
	area := gfx.Rect{Width: 2*gutterPad + textPad + 7*w + barWidth, Height: 180}
	v.SetWrap(true)
	installTestHints(t, v,
		InlayHintSpec{ID: 4, Line: 0, UTF16Column: 2, Label: "typehint", Interactive: true},
		InlayHintSpec{ID: 7, Line: 0, UTF16Column: 5, Label: "EOL", Interactive: true},
	)
	v.Paint(canvas, area, Look{})
	rows := v.rowsOf(v.ref(0))
	for i := 1; i < len(rows); i++ {
		if rows[i-1].at >= rows[i].at {
			t.Fatalf("the same byte anchors several wrap rows: %v", rows)
		}
	}
	seen := map[string]int{}
	for _, label := range lineLabels(canvas, v) {
		if label.Value != "typehint" && label.Value != "EOL" {
			continue
		}
		seen[label.Value]++
		id, _, ok := v.InlayHintAt(label.Bounds.X+1, label.Bounds.Y+1)
		if !ok || label.Value == "typehint" && id != 4 || label.Value == "EOL" && id != 7 {
			t.Fatalf("hint hit on %q returned (%d, %t)", label.Value, id, ok)
		}
	}
	if seen["typehint"] != 1 || seen["EOL"] != 1 {
		t.Fatalf("each hint must draw once, drew %v", seen)
	}
}

func TestInlayHintsLeaveUnderlyingTextAndTabCoordinatesIntact(t *testing.T) {
	v := newTestView(t, "😀\tab")
	canvas := new(gfx.Canvas)
	area := gfx.Rect{X: 31, Y: 20, Width: 600, Height: 150}
	installTestHints(t, v, InlayHintSpec{
		ID: 7, Line: 0, UTF16Column: 2, Label: "T", PaddingLeft: true, Interactive: true,
	})
	v.Paint(canvas, area, Look{})
	v.SetSelection(len("😀\t"), len("😀\t"))
	caret, ok := v.CaretRect()
	if want := v.textLeft + 8*v.CellWidth(); !ok || !near(caret.X, want) {
		t.Fatalf("caret after tab = %+v, want x = %v", caret, want)
	}
	line, col, ok := v.PositionAt(caret.X, caret.Y+1)
	if !ok || line != 0 || col != 3 {
		t.Fatalf("caret position = (%d, %d, %t), want (0, 3, true)", line, col, ok)
	}
	id, hit, ok := v.InlayHintAt(v.textLeft+3.5*v.CellWidth(), caret.Y+1)
	if !ok || id != 7 || !near(hit.Width, 2*v.CellWidth()) {
		t.Fatalf("hint hit = (%d, %+v, %t)", id, hit, ok)
	}
	v.SetSelection(0, len("😀\ta"))
	if got := v.SelectedText(); got != "😀\ta" {
		t.Fatalf("copy would include virtual text: %q", got)
	}
	if got := v.contents(); got != "😀\tab" {
		t.Fatalf("virtual text entered the document: %q", got)
	}
}

func TestInlayHintReplacementKeepsWrappedViewportAndDropsOnEdit(t *testing.T) {
	v := newTestView(t, strings.Repeat("short\n", 80))
	canvas, _ := paintWrapped(t, v, gfx.Rect{Width: 130, Height: 100})
	v.scroll = 25.5 * v.lineH
	first, _, _ := v.VisibleLineRange()
	spec := InlayHintSpec{Line: 20, UTF16Column: 0, Label: "extra-wide-hint"}
	installTestHints(t, v, spec)
	if got, _, _ := v.VisibleLineRange(); got != first {
		t.Fatalf("a hint before the viewport shifted first line from %v to %v", first, got)
	}
	late := prepareTestHints(t, v, spec)
	v.typeText("x")
	if v.SetPreparedInlayHints(late) || v.HasInlayHints() {
		t.Fatal("the editor retained geometry prepared for an old document revision")
	}
	canvas.Reset()
	v.Paint(canvas, v.area, Look{})
	if got := v.rowCount(); got != v.text.LineCount() {
		t.Fatalf("stale hints left %d rows in a %d-line document", got, v.text.LineCount())
	}
}

func TestInlayHintsHorizontalExtentClearsAndLongLinesStayPaged(t *testing.T) {
	area := gfx.Rect{Width: 160, Height: 120}
	canvas := new(gfx.Canvas)
	v := newTestView(t, "short")
	v.Paint(canvas, area, Look{})
	before := v.maxScrollX()
	installTestHints(t, v, InlayHintSpec{Label: "long inlay label expands scroll range", UTF16Column: 5})
	if got := v.maxScrollX(); got <= before {
		t.Fatalf("hint did not extend horizontal scrolling: %v <= %v", got, before)
	}
	if !v.ClearInlayHints() || v.maxScrollX() != before {
		t.Fatalf("horizontal range after clearing hints = %v, want %v", v.maxScrollX(), before)
	}
	v = newTestView(t, strings.Repeat("x", longLine+1)+"\nshort")
	installTestHints(t, v, InlayHintSpec{Label: "too long"}, InlayHintSpec{Line: 1, Label: "normal"})
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	seen := false
	for _, label := range lineLabels(canvas, v) {
		if label.Value == "too long" {
			t.Fatal("virtual hint was inserted into a paged line")
		}
		seen = seen || label.Value == "normal"
	}
	if !seen {
		t.Fatal("a paged line suppressed hints on neighboring lines")
	}
}

func TestInlayHintPaintingAllocatesNothingAfterWarmup(t *testing.T) {
	v := newTestView(t, "let result = run(参数)\nreturn result\n")
	installTestHints(t, v, InlayHintSpec{Line: 0, UTF16Column: 17, Label: "value:"})
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 640, Height: 120}
	paint := func() {
		canvas.Reset()
		v.Paint(canvas, area, Look{})
	}
	for _, wrap := range []bool{false, true} {
		v.SetWrap(wrap)
		paint()
		if allocs := testing.AllocsPerRun(25, paint); allocs != 0 {
			t.Fatalf("painting inline hints with wrap=%t allocates %v times per frame", wrap, allocs)
		}
	}
}

func TestInlayHintViewportSkipsFoldedLinesAndMeasuresMarginInRows(t *testing.T) {
	v := newTestView(t, strings.Repeat("short\n", 4006))
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 500, Height: 150}, Look{})
	v.SetFoldRanges([]FoldRange{{2, 3999}, {4001, 4002}})
	if !v.ToggleFold(2) || !v.ToggleFold(4001) {
		t.Fatal("the fixture's folders could not be collapsed")
	}
	canvas.Reset()
	v.Paint(canvas, gfx.Rect{Width: 500, Height: v.LineHeight() * 3}, Look{})
	v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: 2.5 * v.LineHeight(), Precise: true})

	var buffer [4]LineSpan
	visible := v.ViewportLineRanges(buffer[:0], 0)
	if want := []LineSpan{{2, 2}, {4000, 4001}, {4003, 4003}}; !slices.Equal(visible, want) {
		t.Fatalf("scrolled viewport = %v, want %v", visible, want)
	}
	prefetch := v.ViewportLineRanges(buffer[:0], 2)
	if want := []LineSpan{{0, 2}, {4000, 4001}, {4003, 4005}}; !slices.Equal(prefetch, want) {
		t.Fatalf("rows with prefetch = %v, want %v", prefetch, want)
	}
	if allocs := testing.AllocsPerRun(20, func() { v.ViewportLineRanges(buffer[:0], 2) }); allocs != 0 {
		t.Fatalf("viewport query allocates %v times with a warmed buffer", allocs)
	}
}

func TestInlayHintRequestEndUsesTheDocumentEndOnlyAtEOF(t *testing.T) {
	v := newTestView(t, "text\r\n😀好")
	if line, column := v.InlayHintRequestEnd(0); line != 1 || column != 0 {
		t.Fatalf("position after first line = (%v, %v), want beginning of next line", line, column)
	}
	if line, column := v.InlayHintRequestEnd(1); line != 1 || column != 3 {
		t.Fatalf("position after last line = (%v, %v), want (1, 3)", line, column)
	}
	v = newTestView(t, strings.Repeat("x", longLine+1))
	if line, column := v.InlayHintRequestEnd(0); line != 0 || column != 0 {
		t.Fatalf("position at final paged line = (%v, %v), want (0, 0)", line, column)
	}
}

func TestInlayHintWrappedRowsStayAlignedInTheMinimap(t *testing.T) {
	v := newTestView(t, "before\nshort\nnext")
	v.SetMinimap(true)
	area := gfx.Rect{Width: 170, Height: 110}
	canvas, _ := paintWrapped(t, v, area)
	installTestHints(t, v, InlayHintSpec{Line: 1, UTF16Column: 2, Label: "long-enough-to-wrap"})
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	rows := v.rowsOf(v.ref(1))
	if len(rows) <= 1 {
		t.Fatal("the test hint did not wrap")
	}
	if mapRows := v.minimapRows(v.ref(1)); !slices.Equal(mapRows, rows) {
		t.Fatalf("minimap rows = %v, editor rows = %v", mapRows, rows)
	}
	if end, next := v.lineRowEnd(1), v.lineRow(2); end != next {
		t.Fatalf("minimap selection end row %v differs from the next editor row %v", end, next)
	}
}
