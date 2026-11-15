package editorview

import (
	"strconv"
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// fills is the rectangles of color a paint filled.
func fills(canvas *gfx.Canvas, color gfx.Color) []gfx.Rect {
	var rects []gfx.Rect
	for _, rectangle := range canvas.Rectangles() {
		if rectangle.Color == color {
			rects = append(rects, rectangle.Bounds)
		}
	}
	return rects
}

func TestLineHighlightsTintTheirLinesAndBoundariesARule(t *testing.T) {
	v := gutterView(t, 200)
	added := gfx.RGBA(0, 200, 0, 0.2)
	rule := gfx.RGBA(200, 0, 0, 0.5)
	v.SetLineHighlights([]LineHighlight{
		{StartLine: 150, EndLine: 160, Color: added},
		{StartLine: 3, EndLine: 5, Color: added},
		{StartLine: 8, EndLine: 99, Color: rule, Boundary: true},
		{StartLine: -1, EndLine: 4, Color: added},
		{StartLine: 9, EndLine: 9},
	})
	if d := v.decor.highlights; len(d) != 3 || d[0].StartLine != 3 || d[1].EndLine != 8 || d[2].StartLine != 150 {
		t.Fatalf("highlights = %+v", d)
	}
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
	tints := fills(canvas, added)
	if len(tints) != 1 {
		t.Fatalf("tinted %d spans in view, want only the one of lines 3 to 5: %+v", len(tints), tints)
	}
	if got := tints[0]; got.X != 0 || got.Y != 3*v.lineH || got.Height != 3*v.lineH || got.Width != v.textRight {
		t.Fatalf("tint of lines 3 to 5 = %+v, want the gutter and the text of them", got)
	}
	rules := fills(canvas, rule)
	if len(rules) != 1 || rules[0].Y != 8*v.lineH || rules[0].Height != 1 {
		t.Fatalf("boundary at line 8 = %+v", rules)
	}
	// Scrolled down, the span out of view is not painted and the one in view is.
	canvas.Reset()
	v.SetScrollOffset(0, 140*v.lineH)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
	if tints := fills(canvas, added); len(tints) != 1 || tints[0].Y != 10*v.lineH {
		t.Fatalf("tints scrolled to line 140 = %+v", tints)
	}
}

func TestBoundaryAtTheEndOfTheTextIsInsideTheLastLine(t *testing.T) {
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte("a\nb"))})
	t.Cleanup(v.Close)
	rule := gfx.RGBA(200, 0, 0, 0.5)
	v.SetLineHighlights([]LineHighlight{{StartLine: 2, Color: rule, Boundary: true}})
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
	if rules := fills(canvas, rule); len(rules) != 1 || rules[0].Y != 2*v.lineH-1 {
		t.Fatalf("boundary at the end = %+v, want the last pixel row of line 1", rules)
	}
}

func TestLineLabelsReplaceTheNumbersAndSizeTheGutter(t *testing.T) {
	v := gutterView(t, 5)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 400}
	v.Paint(canvas, area, Look{})
	numbered := v.textLeft
	v.SetLineLabels([]string{"10 12", "", "11 13"})
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	var got []string
	for _, text := range numberLabels(canvas, v) {
		got = append(got, text.Value)
	}
	if strings.Join(got, "|") != "10 12|11 13" {
		t.Fatalf("labels = %q, want the two labels and none for the empty one or the lines past them", got)
	}
	if want := numbered + 3*v.cellW; v.textLeft != want {
		t.Fatalf("text starts at %v, want %v: the gutter is as wide as five cells", v.textLeft, want)
	}
	v.SetLineLabels(nil)
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	if labels := numberLabels(canvas, v); len(labels) != 6 || labels[0].Value != "1" || v.textLeft != numbered {
		t.Fatalf("numbers after the labels went = %d, text at %v", len(labels), v.textLeft)
	}
}

func TestCenterLineScrollsTheLineToTheMiddle(t *testing.T) {
	v := gutterView(t, 500)
	area := gfx.Rect{Y: 30, Width: 600, Height: 400}
	if _, ok := v.LineAt(40); ok || v.LineHeight() != 0 {
		t.Fatal("a view not painted yet has no lines at a place")
	}
	v.CenterLine(300)
	v.Paint(new(gfx.Canvas), area, Look{})
	lineH := v.LineHeight()
	top := v.LineTop(300)
	if middle := area.Y + area.Height/2; top > middle || top+lineH < middle {
		t.Fatalf("line 300 is at %v, want it across the middle %v", top, middle)
	}
	if line, ok := v.LineAt(top + lineH/2); !ok || line != 300 {
		t.Fatalf("LineAt the middle of line 300 = %d %v", line, ok)
	}
	if _, ok := v.LineAt(area.Y - 1 - v.scroll); ok {
		t.Fatal("a place above the first row has a line")
	}
	// The scroll goes no further than the text: line 499 centered stops at the bottom.
	v.CenterLine(499)
	v.Paint(new(gfx.Canvas), area, Look{})
	if _, y := v.ScrollOffset(); y != v.maxScroll() {
		t.Fatalf("scroll = %v, want the end %v", y, v.maxScroll())
	}
	if got := v.LineTop(v.text.LineCount()); got != area.Y+float32(v.rowCount())*lineH-v.scroll {
		t.Fatalf("LineTop of the end = %v", got)
	}
	// SetScrollOffset keeps the scroll in range once painted.
	v.SetScrollOffset(-5, 1e9)
	if x, y := v.ScrollOffset(); x != 0 || y != v.maxScroll() {
		t.Fatalf("scroll set out of range = %v %v", x, y)
	}
}

// Highlights and labels add nothing a repaint allocates.
func TestRepaintWithHighlightsAndLabelsAllocatesNothing(t *testing.T) {
	v := gutterView(t, 3000)
	highlights := make([]LineHighlight, 0, 300)
	labels := make([]string, 3001)
	for i := range 300 {
		highlights = append(highlights, LineHighlight{StartLine: i * 10, EndLine: i*10 + 2, Color: gfx.RGBA(0, 200, 0, 0.2)})
		highlights = append(highlights, LineHighlight{StartLine: i*10 + 5, Color: gfx.RGBA(200, 0, 0, 0.5), Boundary: true})
	}
	for i := range labels {
		labels[i] = strconv.Itoa(i + 7)
	}
	v.SetLineHighlights(highlights)
	v.SetLineLabels(labels)
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 600}
	paint := func() {
		canvas.Reset()
		v.Paint(canvas, area, Look{})
	}
	paint()
	v.SetScrollOffset(0, 1000*v.lineH)
	paint()
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a repaint allocates %v times, want none", allocs)
	}
}

func TestAnnotationIconMovesItsTextAndRuleRunsToTheEdge(t *testing.T) {
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte("a\n\nb"))})
	t.Cleanup(v.Close)
	v.SetLineAnnotations([]LineAnnotation{
		{Line: 0, Text: "plain"},
		{Line: 1, Text: "folded", Icon: gfx.Icon{ViewBox: 24}, Rule: true},
	})
	canvas := new(gfx.Canvas)
	look := Look{Subtle: gfx.RGBA(10, 20, 30, 1)}
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, look)
	at := map[string]float32{}
	for _, text := range canvas.Texts() {
		if text.Value == "plain" || text.Value == "folded" {
			at[text.Value] = text.Bounds.X
		}
	}
	// "a" is one cell longer than the empty line, so without an icon "folded" would start a
	// cell left of "plain"; the icon puts it its cells further right.
	if want := at["plain"] - v.cellW + annotationIconCells*v.cellW; at["folded"] != want {
		t.Fatalf("folded starts at %v, want %v after its icon (plain at %v)", at["folded"], want, at["plain"])
	}
	var rules []gfx.Rect
	for _, rectangle := range canvas.Rectangles() {
		r := rectangle.Bounds
		if r.Height == 1 && r.Y > v.lineH && r.Y < 2*v.lineH && r.X+r.Width == v.textRight {
			rules = append(rules, r)
		}
	}
	if len(rules) != 1 || rules[0].X <= at["folded"] {
		t.Fatalf("rules of the folded row = %+v, want one after its text to the right edge", rules)
	}
}

func TestHideVerticalBarGivesTheHorizontalBarTheWidth(t *testing.T) {
	v := gutterView(t, 500)
	area := gfx.Rect{Width: 600, Height: 400}
	canvas := new(gfx.Canvas)
	v.Paint(canvas, area, Look{})
	if v.bars.vertical.Width == 0 {
		t.Fatal("a long text has no vertical bar")
	}
	shown := v.bars.horizontal.Width
	v.HideVerticalBar()
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	if v.bars.vertical != (gfx.Rect{}) {
		t.Fatalf("hidden vertical bar = %+v", v.bars.vertical)
	}
	if got := v.bars.horizontal.Width; got != shown+barTrack {
		t.Fatalf("horizontal bar width = %v, want %v reaching the edge", got, shown+barTrack)
	}
}

// An inline highlight is laid out on the cells of its line: UTF-16 columns past a tab, a wide
// character and a surrogate pair land on the cells they take, and one that cannot be placed is
// dropped.
func TestInlineHighlightsTintTheCellsOfTheirColumns(t *testing.T) {
	// Line 1: a tab (cells 0-3), 中 (4-5), 😀 (two UTF-16 units, 6-7), then "xy" (8-9). The last
	// line is wider than the view, so the view scrolls sideways.
	v := New(Config{HitID: gfx.Item(1), Label: "test", Content: Prepare([]byte("plain\n\t中😀xy\nlast" + strings.Repeat("z", 200)))})
	t.Cleanup(v.Close)
	word := gfx.RGBA(0, 0, 200, 0.3)
	other := gfx.RGBA(0, 200, 0, 0.3)
	v.SetInlineHighlights([]InlineHighlight{
		{Line: 1, Start: 2, End: 4, Color: word},  // 😀
		{Line: 1, Start: 0, End: 2, Color: other}, // the tab and 中
		{Line: 0, Start: 1, End: 3, Color: word},  // "la"
		{Line: 1, Start: 3, End: 5, Color: word},  // starts inside the surrogate pair
		{Line: 1, Start: 4, End: 9, Color: word},  // runs past the line
		{Line: 2, Start: 1, End: 1, Color: word},  // covers nothing
		{Line: 3, Start: 0, End: 1, Color: word},  // past the text
		{Line: 2, Start: 0, End: 2},               // transparent
	})
	want := []inlineSpan{{line: 0, from: 1, to: 3, color: word}, {line: 1, from: 6, to: 8, color: word}, {line: 1, from: 0, to: 6, color: other}}
	if got := v.decor.inline; len(got) != len(want) || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("spans = %+v, want %+v", got, want)
	}
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
	tints := fills(canvas, word)
	if len(tints) != 2 {
		t.Fatalf("tinted %d spans, want 2: %+v", len(tints), tints)
	}
	if got := tints[1]; got.X != v.textLeft+6*v.cellW || got.Width != 2*v.cellW || got.Y != v.lineH || got.Height != v.lineH {
		t.Fatalf("tint of 😀 = %+v, want cells 6 to 8 of line 1", got)
	}
	if got := fills(canvas, other); len(got) != 1 || got[0].X != v.textLeft || got[0].Width != 6*v.cellW {
		t.Fatalf("tint of the tab and 中 = %+v, want cells 0 to 6", got)
	}
	// Scrolled sideways, a tint moves with its text.
	canvas.Reset()
	v.SetScrollOffset(2*v.cellW, 0)
	v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
	if got := fills(canvas, word); len(got) != 2 || got[1].X != v.textLeft+4*v.cellW {
		t.Fatalf("tints scrolled two cells = %+v", got)
	}
	// Setting none clears them.
	v.SetInlineHighlights(nil)
	if len(v.decor.inline) != 0 {
		t.Fatalf("spans after clearing = %+v", v.decor.inline)
	}
}

// Inline highlights add nothing a repaint allocates.
func TestRepaintWithInlineHighlightsAllocatesNothing(t *testing.T) {
	v := gutterView(t, 3000)
	words := make([]InlineHighlight, 0, 600)
	for i := range 300 {
		words = append(words, InlineHighlight{Line: i * 10, Start: 0, End: 2, Color: gfx.RGBA(0, 0, 200, 0.3)})
		words = append(words, InlineHighlight{Line: i * 10, Start: 3, End: 4, Color: gfx.RGBA(0, 0, 200, 0.3)})
	}
	v.SetInlineHighlights(words)
	if len(v.decor.inline) == 0 {
		t.Fatal("no inline highlight was placed")
	}
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 900, Height: 600}
	paint := func() {
		canvas.Reset()
		v.Paint(canvas, area, Look{})
	}
	paint()
	v.SetScrollOffset(0, 1000*v.lineH)
	paint()
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("a repaint allocates %v times, want none", allocs)
	}
}
