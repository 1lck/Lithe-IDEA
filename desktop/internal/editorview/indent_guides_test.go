package editorview

import (
	"math"
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

func TestIndentGuidesKeepIndentationBlocksAlongsideBraceScopes(t *testing.T) {
	source := "def collect():\n    mapping = {\n        'first': 1,\n    }\n    if enabled:\n        gather()\n        refine()\n    if other:\n        discard()\n"
	v := newTestView(t, source)
	v.hl.Close()
	text := v.TextSnapshot()
	v.SetIndentGuideScopes(PrepareIndentGuideScopes(text, []IndentGuideScope{{
		Open: strings.IndexByte(source, '{'), Close: strings.IndexByte(source, '}'),
	}}))
	v.SetPresentation(Presentation{IndentGuides: true})
	caret := strings.Index(source, "gather")
	v.SetSelection(caret, caret)
	canvas := new(gfx.Canvas)
	foreground := gfx.RGB24(0xCDD2D8)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 420}, Look{Foreground: foreground})

	var guides, active [9]int
	for _, rect := range canvas.Rectangles() {
		if rect.Bounds.Width != 1 || rect.Color.Red != foreground.Red {
			continue
		}
		line := int(rect.Bounds.Y / v.lineH)
		if line < 0 || line >= len(guides) {
			t.Fatalf("guide outside code at y=%v", rect.Bounds.Y)
		}
		guides[line]++
		if rect.Color.Alpha > 0.4 {
			active[line]++
		}
	}
	if want := [9]int{0, 1, 1, 1, 1, 2, 2, 1, 2}; guides != want {
		t.Fatalf("guides by line = %v, want %v", guides, want)
	}
	if want := [9]int{5: 1, 6: 1}; active != want {
		t.Fatalf("active guides by line = %v, want %v", active, want)
	}
}

func TestIndentGuidesConnectOuterIndentationThroughNestedDictionary(t *testing.T) {
	source := "def collect():\n    if enabled:\n        mapping = {\n            'first': 1,\n        }\n        gather()\n"
	v := newTestView(t, source)
	v.hl.Close()
	text := v.TextSnapshot()
	v.SetIndentGuideScopes(PrepareIndentGuideScopes(text, []IndentGuideScope{{
		Open: strings.IndexByte(source, '{'), Close: strings.IndexByte(source, '}'),
	}}))
	v.SetPresentation(Presentation{IndentGuides: true, IndentGuideColors: []string{"#E17C5F", "#63BBA8"}})
	canvas := new(gfx.Canvas)
	for _, tc := range []struct {
		caret        string
		activeColumn int
	}{{"if enabled", 4}, {"gather", 8}} {
		caret := strings.Index(source, tc.caret)
		v.SetSelection(caret, caret)
		canvas.Reset()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 420}, Look{Foreground: gfx.RGB24(0xCDD2D8)})

		// Both guides are visible on the dictionary body, and only the caret's
		// surrounding indentation is emphasized through the structural segment.
		for i, column := range [...]int{4, 8} {
			ink := gfx.RGB24([...]uint32{0xE17C5F, 0x63BBA8}[i])
			if column == tc.activeColumn {
				ink.Alpha = 0.9
			} else {
				ink.Alpha = 0.45
			}
			found := false
			wantX := float32(math.Floor(float64(v.textLeft+float32(column)*v.cellW))) - 1
			for _, rect := range canvas.Rectangles() {
				if rect.Bounds.Width == 1 && rect.Bounds.Y == 3*v.lineH && rect.Bounds.X == wantX && rect.Color == ink {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("caret at %q: column %d guide missing or incorrectly styled in dictionary body", tc.caret, column)
			}
		}
	}
}

func TestIndentGuideAlignsToOpeningLineWhenCloserFollowsCode(t *testing.T) {
	for _, tc := range []struct {
		name, closeLine string
		column          int
	}{
		{"inline", "        finish(); }", 4},
		{"leading", "  }", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := "class Sample {\n    void run() {\n        start();\n" + tc.closeLine + "\n}\n"
			v := newTestView(t, source)
			v.hl.Close()
			text := v.TextSnapshot()
			v.SetIndentGuideScopes(PrepareIndentGuideScopes(text, []IndentGuideScope{
				{Open: text.LineEnd(0) - 1, Close: text.LineEnd(4) - 1},
				{Open: text.LineEnd(1) - 1, Close: text.LineEnd(3) - 1},
			}))
			caret := strings.Index(source, "start")
			v.SetSelection(caret, caret)
			v.SetPresentation(Presentation{IndentGuides: true})
			canvas := new(gfx.Canvas)
			foreground := gfx.RGB24(0xCDD2D8)
			v.Paint(canvas, gfx.Rect{Width: 600, Height: 420}, Look{Foreground: foreground})
			wantX := float32(math.Floor(float64(v.textLeft+float32(tc.column)*v.cellW))) - 1
			count := 0
			for _, rect := range canvas.Rectangles() {
				if rect.Bounds.Width != 1 || rect.Color.Red != foreground.Red || rect.Color.Alpha < 0.4 {
					continue
				}
				if rect.Bounds.X != wantX || rect.Bounds.Y != 2*v.lineH {
					t.Fatalf("active guide at (%v,%v), want (%v,%v)", rect.Bounds.X, rect.Bounds.Y, wantX, 2*v.lineH)
				}
				count++
			}
			if count != 1 {
				t.Fatalf("painted %d active guide segments, want one on the block body", count)
			}
		})
	}
}
