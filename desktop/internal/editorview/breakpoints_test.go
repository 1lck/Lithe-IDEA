package editorview

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestBreakpointsAreSortedAndOnePerLine(t *testing.T) {
	v := gutterView(t, 20)
	v.SetBreakpoints([]Breakpoint{{Line: 9}, {Line: 2, Log: true}, {Line: -1}, {Line: 9, Disabled: true}, {Line: 4}})
	got := v.gutter.breakpoints
	if len(got) != 3 || got[0].Line != 2 || got[1].Line != 4 || got[2].Line != 9 || got[2].Disabled {
		t.Fatalf("breakpoints = %+v", got)
	}
	if v.gutter.breakpointFrom(3) != 1 || v.gutter.breakpointFrom(10) != 3 {
		t.Fatal("the search for the first breakpoint in view is off")
	}
}

// A breakpoint is drawn in place of its line's number, so the gutter keeps its width.
func TestBreakpointReplacesTheLineNumber(t *testing.T) {
	v := gutterView(t, 20)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 400}
	v.Paint(canvas, area, Look{})
	left := v.textLeft
	v.SetBreakpoints([]Breakpoint{{Line: 3}})
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	if v.textLeft != left {
		t.Fatalf("the text moved from %v to %v", left, v.textLeft)
	}
	numbers := map[string]bool{}
	for _, text := range canvas.Texts() {
		numbers[text.Value] = true
	}
	if numbers["4"] || !numbers["3"] || !numbers["5"] {
		t.Fatalf("numbers drawn = %v, want every number but line 3's", numbers)
	}
	marks := 0
	for _, rect := range canvas.Rectangles() {
		if rect.Bounds.X < v.numbersRight && rect.Radius > 0 && rect.Color == breakpointColor(Look{}, false) {
			marks++
		}
	}
	if marks != 1 {
		t.Fatalf("%d breakpoint marks drawn, want one", marks)
	}
}

// A press on a line number toggles the line's breakpoint while the host takes it; the Git bar
// left of the numbers keeps its press, and without a host a press places the caret.
func TestBreakpointPressOnTheLineNumber(t *testing.T) {
	v := gutterView(t, 20)
	v.Paint(new(gfx.Canvas), gfx.Rect{Width: 600, Height: 400}, Look{})
	press := func(x float32, line int) gfx.PointerEvent {
		return gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, Target: v.cfg.HitID, X: x, Y: v.area.Y + float32(line)*v.lineH + 1}
	}
	number := (v.area.X + v.numbersRight) / 2
	if v.breakpointPointer(press(number, 5)) {
		t.Fatal("a press was taken without a host")
	}
	var lines []int
	v.SetBreakpointClick(func(line int) { lines = append(lines, line) })
	if !v.breakpointPointer(press(number, 5)) || len(lines) != 1 || lines[0] != 5 {
		t.Fatalf("toggled lines = %v, want line 5", lines)
	}
	if v.breakpointPointer(press(v.area.X+gutterBarX+1, 6)) {
		t.Fatal("a press on the Git bar was taken")
	}
	if v.breakpointPointer(press(v.textLeft+20, 6)) {
		t.Fatal("a press in the text was taken")
	}
	// Through the view's own pointer handling the press toggles and leaves the caret.
	caret := v.caret
	if result, ok := v.Pointer(press(number, 7)); !ok || !result.Handled || len(lines) != 2 || lines[1] != 7 || v.caret != caret {
		t.Fatalf("pointer = %+v %v, lines %v, caret %d (was %d)", result, ok, lines, v.caret, caret)
	}
}

// A frame with breakpoints in view allocates nothing.
func TestBreakpointPaintDoesNotAllocate(t *testing.T) {
	v := gutterView(t, 2000)
	var points []Breakpoint
	for line := 0; line < 2000; line += 3 {
		points = append(points, Breakpoint{Line: line, Disabled: line%2 == 0, Conditional: line%5 == 0, Log: line%7 == 0})
	}
	v.SetBreakpoints(points)
	v.SetBreakpointClick(func(int) {})
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 400}
	paint := func() { canvas.Reset(); v.Paint(canvas, area, Look{}) }
	paint()
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a frame with breakpoints allocated %v times", allocs)
	}
}
