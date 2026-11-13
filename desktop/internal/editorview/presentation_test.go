package editorview

import (
	"github.com/vivaui/viva/gfx"
	"testing"
)

func TestPresentationHidesNumbersWithoutLosingBreakpointMargin(t *testing.T) {
	v := newTestView(t, "one\ntwo\nthree")
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 300}
	v.Paint(canvas, area, Look{})
	before := v.textLeft
	if len(numberLabels(canvas, v)) != 3 {
		t.Fatal("initial line numbers missing")
	}
	v.SetPresentation(Presentation{HideLineNumbers: true})
	paintAgain(v, canvas, area)
	if len(numberLabels(canvas, v)) != 0 || v.textLeft >= before || v.textLeft <= textPad {
		t.Fatalf("hidden numbers: left=%v before=%v", v.textLeft, before)
	}
}

func TestSearchHighlightInvalidatesWhenDocumentChanges(t *testing.T) {
	v := newTestView(t, "alpha beta")
	v.SetSearchMatches([]Range{{0, 5}})
	if v.searchRevision != v.revision || len(v.searchRanges) != 1 {
		t.Fatal("search ranges were not installed")
	}
	v.typeText("x")
	if v.searchRevision == v.revision {
		t.Fatal("edit left the searched revision current")
	}
	v.ClearSearchMatches()
	if len(v.searchRanges) != 0 {
		t.Fatal("closed find retained ranges")
	}
}

func TestConfiguredCaretStyleAppliesToTheNativePaint(t *testing.T) {
	v := newTestView(t, "x")
	v.cellW, v.lineH = 8, 18
	for _, style := range []string{"line", "block", "underline"} {
		v.SetPresentation(Presentation{CursorStyle: style})
		canvas := new(gfx.Canvas)
		v.paintConfiguredCaret(canvas, 20, 30, gfx.RGB24(0xffffff))
		if len(canvas.Rectangles()) != 1 {
			t.Fatalf("%s caret count: %d", style, len(canvas.Rectangles()))
		}
		width, height := float32(2), float32(18)
		if style == "block" {
			width = 8
		}
		if style == "underline" {
			width, height = 8, 2
		}
		if rect := canvas.Rectangles()[0].Bounds; rect.Width != width || rect.Height != height {
			t.Fatalf("%s caret: %+v", style, rect)
		}
	}
}
