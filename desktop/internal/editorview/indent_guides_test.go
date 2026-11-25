package editorview

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestIndentGuidesFollowColumnsAndAppearances(t *testing.T) {
	v := newTestView(t, "class Sample {\r\n    void run() {\r\n\t    action();\r\n\r\n        action();\r\n    }\r\n}\r\n")
	v.hl.Close()
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 240}
	foreground, first, second := gfx.RGB24(0xCDD2D8), gfx.RGB24(0xE17C5F), gfx.RGB24(0x63BBA8)
	neutral := foreground
	neutral.Alpha, first.Alpha, second.Alpha = 0.16, 0.45, 0.45
	look := Look{Foreground: foreground}
	paint := func() {
		canvas.Reset()
		v.Paint(canvas, area, look)
	}
	count := func(color gfx.Color) int {
		total := 0
		for _, rect := range canvas.Rectangles() {
			if rect.Color == color && rect.Bounds.Width == 1 {
				total++
			}
		}
		return total
	}
	v.SetPresentation(Presentation{IndentGuides: true})
	paint()
	if got := count(neutral); got != 8 {
		t.Fatalf("painted %d neutral guides, want 8 including the lines through a blank row", got)
	}
	colors := []string{"#E17C5F", "#63BBA8"}
	v.SetPresentation(Presentation{IndentGuides: true, IndentGuideColors: colors})
	paint()
	if a, b := count(first), count(second); a != 5 || b != 3 {
		t.Fatalf("painted %d outer and %d inner guides, want 5 and 3", a, b)
	}
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("warm guide paint allocated %v times", allocs)
	}
	v.SetPresentation(Presentation{IndentGuideColors: colors})
	paint()
	if got := count(neutral) + count(first) + count(second); got != 0 {
		t.Fatalf("master switch off left %d guides", got)
	}
}

func TestIndentGuidesBoundAndEmphasizeTheCaretScope(t *testing.T) {
	source := "class Sample {\n    void run() {\n        if (ready) {\n            first();\n            second();\n        }\n        if (other) {\n            third();\n        }\n    }\n}\n"
	v := newTestView(t, source)
	v.hl.Close()
	text := v.TextSnapshot()
	pair := func(open, close int) IndentGuideScope {
		return IndentGuideScope{Open: text.LineEnd(open) - 1, Close: text.LineEnd(close) - 1}
	}
	v.SetIndentGuideScopes(PrepareIndentGuideScopes(text, []IndentGuideScope{
		pair(0, 10), pair(1, 9), pair(2, 5), pair(6, 8),
	}))
	v.SetPresentation(Presentation{IndentGuides: true})
	canvas := new(gfx.Canvas)
	foreground := gfx.RGB24(0xCDD2D8)
	area := gfx.Rect{Width: 600, Height: 420}
	for _, tc := range []struct {
		caret       string
		first, rows int
	}{{"first", 3, 2}, {"third", 7, 1}} {
		caret := strings.Index(source, tc.caret)
		v.SetSelection(caret, caret)
		canvas.Reset()
		v.Paint(canvas, area, Look{Foreground: foreground})
		highlighted := 0
		for _, rect := range canvas.Rectangles() {
			if rect.Bounds.Width != 1 || rect.Color.Red != foreground.Red || rect.Color.Alpha < 0.4 {
				continue
			}
			if want := float32(tc.first+highlighted) * v.lineH; rect.Bounds.Y != want {
				t.Fatalf("caret at %s highlighted y=%v, want %v inside the block", tc.caret, rect.Bounds.Y, want)
			}
			highlighted++
		}
		if highlighted != tc.rows {
			t.Fatalf("caret at %s highlighted %d rows, want %d", tc.caret, highlighted, tc.rows)
		}
	}
}
