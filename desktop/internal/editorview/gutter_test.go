package editorview

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

func gutterView(t *testing.T, lines int) *View {
	t.Helper()
	text := strings.Repeat("line of text\n", lines)
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte(text))})
	t.Cleanup(v.Close)
	return v
}

func TestGutterDecorationsAreSortedAndLookedUpByLine(t *testing.T) {
	v := gutterView(t, 100)
	v.SetGutterDecorations([]GutterDecoration{
		{Kind: GutterModified, StartLine: 40, EndLine: 45},
		{Kind: GutterAdded, StartLine: 5, EndLine: 9},
		{Kind: GutterDeleted, StartLine: 20, EndLine: 99},
		{Kind: 0, StartLine: 1},
		{Kind: GutterAdded, StartLine: -1},
	})
	g := &v.gutter
	if len(g.decorations) != 3 || g.decorations[0].StartLine != 5 || g.decorations[2].StartLine != 40 {
		t.Fatalf("decorations = %+v", g.decorations)
	}
	if d := g.decorations[1]; d.EndLine != 20 {
		t.Fatalf("a deletion keeps no span: %+v", d)
	}
	for line, want := range map[int]GutterKind{5: GutterAdded, 9: GutterAdded, 20: GutterDeleted, 43: GutterModified} {
		if d, ok := g.decorationAt(line); !ok || d.Kind != want {
			t.Errorf("line %d = %+v %v, want %d", line, d, ok, want)
		}
	}
	for _, line := range []int{0, 10, 19, 21, 46, 99} {
		if _, ok := g.decorationAt(line); ok {
			t.Errorf("line %d is decorated", line)
		}
	}
}

func TestGutterClickOnlyOnDecoratedLinesWhenClickable(t *testing.T) {
	v := gutterView(t, 50)
	v.SetGutterDecorations([]GutterDecoration{{Kind: GutterModified, StartLine: 2, EndLine: 3}})
	var got []GutterClick
	v.Paint(new(gfx.Canvas), gfx.Rect{Width: 600, Height: 400}, Look{})
	press := func(line int) bool {
		y := v.area.Y + float32(line)*v.lineH + 1
		return v.gutterPointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: v.area.X + 4, Y: y})
	}
	v.SetGutterClick(false, func(c GutterClick) { got = append(got, c) })
	if press(2) {
		t.Fatal("a click was taken while not clickable")
	}
	v.SetGutterClick(true, func(c GutterClick) { got = append(got, c) })
	if !press(3) || len(got) != 1 || got[0].Line != 3 || got[0].Kind != GutterModified {
		t.Fatalf("clicks = %+v", got)
	}
	if press(10) || len(got) != 1 {
		t.Fatal("a click on an undecorated line was taken")
	}
	// A press in the text is not the gutter's.
	if v.gutterPointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: v.textLeft + 20, Y: v.area.Y + 2*v.lineH + 1}) {
		t.Fatal("a press in the text was taken")
	}
}

func TestLineAnnotationsAreSortedAndNotPartOfTheText(t *testing.T) {
	v := gutterView(t, 10)
	v.SetLineAnnotations([]LineAnnotation{{Line: 5, Text: "b"}, {Line: 1, Text: "a"}, {Line: 2}, {Line: -1, Text: "x"}})
	if g := v.gutter.annotations; len(g) != 2 || g[0].Line != 1 || g[1].Line != 5 {
		t.Fatalf("annotations = %+v", g)
	}
	if strings.Contains(v.text.String(), "a") && strings.Contains(v.text.String(), "blame") {
		t.Fatal("annotation entered the text")
	}
	v.SetSelection(0, v.text.Len())
	if strings.Contains(v.SelectedText(), "b") && strings.Count(v.SelectedText(), "b") > 0 {
		t.Fatal("annotation entered the selection")
	}
}

func TestDecorationsAndAnnotationsPaintOnlyVisibleLinesWithoutAllocating(t *testing.T) {
	v := gutterView(t, 2000)
	var decorations []GutterDecoration
	var annotations []LineAnnotation
	for line := 0; line < 2000; line += 2 {
		decorations = append(decorations, GutterDecoration{Kind: GutterAdded, StartLine: line, EndLine: line})
		annotations = append(annotations, LineAnnotation{Line: line, Text: "blame"})
	}
	v.SetGutterDecorations(decorations)
	v.SetLineAnnotations(annotations)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 400}
	paint := func() { canvas.Reset(); v.Paint(canvas, area, Look{}) }
	paint()
	visible := 0
	for _, text := range canvas.Texts() {
		if text.RunCount > 0 && text.Value == "blame" {
			visible++
		}
	}
	if visible == 0 || visible > 30 {
		t.Fatalf("%d annotations painted for a 400 point view", visible)
	}
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a frame with decorations allocated %v times", allocs)
	}
}
