package editorview

import (
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/gfx"
)

func textInColor(canvas *gfx.Canvas, color gfx.Color) string {
	var out strings.Builder
	for _, label := range canvas.Texts() {
		at := 0
		for _, run := range canvas.TextRuns(label) {
			end := at + int(run.Bytes)
			if run.Color == color {
				out.WriteString(label.Value[at:end])
			}
			at = end
		}
	}
	return out.String()
}

func TestRainbowBracketColorsShareTheEditorOverlay(t *testing.T) {
	view := newTestView(t, "😀([])")
	text := view.TextSnapshot()
	rangeColor := ColorDecoration{
		StartLine: 0, StartCharacter: 3, EndLine: 0, EndCharacter: 4,
		Light: "#123456", Dark: "#654321",
	}
	prepared := PrepareColorDecorations(text, []ColorDecoration{rangeColor}).WithRainbowColors(
		[]RainbowColor{{Start: 4, End: 5}, {Start: 5, End: 6, Color: 1}, {Start: 6, End: 7, Color: 1}, {Start: 7, End: 8}},
		[]string{"#AB0000", "#00AB00"}, []string{"#EF0000", "#00EF00"},
	)
	if !view.SetPreparedColorDecorations(prepared) {
		t.Fatal("colors were rejected for the current text")
	}
	for _, appearance := range []struct {
		dark                   bool
		outer, inner, provider uint32
	}{
		{false, 0xAB0000, 0x00AB00, 0x123456},
		{true, 0xEF0000, 0x00EF00, 0x654321},
	} {
		canvas := new(gfx.Canvas)
		view.Paint(canvas, gfx.Rect{Width: 600, Height: 100}, Look{Dark: appearance.dark})
		for color, want := range map[uint32]string{appearance.outer: "()", appearance.inner: "]", appearance.provider: "["} {
			if got := textInColor(canvas, gfx.RGB24(color)); got != want {
				t.Errorf("dark=%t color #%06x = %q, want %q", appearance.dark, color, got, want)
			}
		}
	}
}

// Color ranges override foreground only. LSP token identity, style, selection backgrounds,
// another line's colors, and theme changes keep their independent rendering behavior.
func TestColorDecorationsComposeWithSemanticTokensAndThemes(t *testing.T) {
	v := newTestView(t, "header\nfirst second")
	text := v.TextSnapshot()
	legend := syntax.NewSemanticLegend([]string{"class"}, []string{"deprecated"})
	v.SetSemantic(text, legend, []syntax.SemanticToken{{Line: 1, StartChar: 0, Length: 12, Modifiers: 1}})
	prepared := PrepareColorDecorations(text, []ColorDecoration{{StartLine: 1, StartCharacter: 0, EndLine: 1, EndCharacter: 5, Light: "#C00050", Dark: "#FF80B0"}})
	if !v.SetPreparedColorDecorations(prepared) {
		t.Fatal("current text was rejected")
	}
	v.SetSelection(len("header\n"), len("header\nfirst"))
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 220}
	for _, dark := range []bool{false, true} {
		canvas.Reset()
		selection := gfx.RGB24(0xABCDEF)
		v.Paint(canvas, area, Look{Dark: dark, Selection: selection})
		wantColor := gfx.RGB24(0xC00050)
		if dark {
			wantColor = gfx.RGB24(0xFF80B0)
		}
		if got := textInColor(canvas, wantColor); got != "first" {
			t.Fatalf("dark=%t decorated text=%q, want first on line 1", dark, got)
		}
		if len(fills(canvas, selection)) != 1 {
			t.Fatal("foreground decoration changed the selection background")
		}
		for _, label := range canvas.Texts() {
			for _, run := range canvas.TextRuns(label) {
				if run.Color == wantColor && !run.Strike {
					t.Fatal("foreground decoration removed the semantic strikethrough")
				}
			}
		}
	}
	if got := v.SyntaxLine(nil, 1); len(got) == 0 || got[0].Name.String() != "class.deprecated" {
		t.Fatalf("decoration replaced LSP semantic identity: %v", got)
	}
	v.ClearColorDecorations()
	canvas.Reset()
	v.Paint(canvas, area, Look{})
	if textInColor(canvas, gfx.RGB24(0xC00050)) != "" {
		t.Fatal("cleared provider colors remained visible")
	}
}

// colorSpans is the view's provider colors as byte ranges of its text, in order.
func colorSpans(v *View) [][2]int {
	var spans [][2]int
	for _, span := range v.decor.colors {
		spans = append(spans, [2]int{int(span.start), int(span.end)})
	}
	return spans
}

func requireColorSpans(t *testing.T, v *View, what string, want ...[2]int) {
	t.Helper()
	if got := colorSpans(v); !slices.Equal(got, want) {
		t.Fatalf("%s: colors cover %v, want %v", what, got, want)
	}
}

func TestColorDecorationsConvertUTF16OnceAndShareColors(t *testing.T) {
	v := newTestView(t, "😀a\r\n界b")
	decorations := []ColorDecoration{
		{StartLine: 0, StartCharacter: 2, EndLine: 0, EndCharacter: 3, Light: "#112233", Dark: "#445566"},
		{StartLine: 1, StartCharacter: 1, EndLine: 1, EndCharacter: 2, Light: "#112233", Dark: "#445566"},
	}
	prepared := PrepareColorDecorations(v.TextSnapshot(), decorations)
	if !v.SetPreparedColorDecorations(prepared) {
		t.Fatal("current text was rejected")
	}
	requireColorSpans(t, v, "UTF-16 columns", [2]int{len("😀"), len("😀a")}, [2]int{len("😀a\r\n界"), len("😀a\r\n界b")})
	if len(v.decor.colorPalette) != 1 {
		t.Fatalf("two ranges of one color keep %d palette entries, want 1", len(v.decor.colorPalette))
	}
	bad := PrepareColorDecorations(rope.FromString("😀"), []ColorDecoration{{StartLine: 0, StartCharacter: 1, EndLine: 0, EndCharacter: 2, Light: "#112233", Dark: "#445566"}})
	if len(bad.spans) != 0 {
		t.Fatal("a range cut a surrogate pair")
	}
	unordered := PrepareColorDecorations(rope.FromString("ab\ncd"), []ColorDecoration{
		{StartLine: 1, StartCharacter: 0, EndLine: 1, EndCharacter: 1, Light: "#112233", Dark: "#445566"},
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 1, Light: "#112233", Dark: "#445566"},
		{StartLine: 1, StartCharacter: 1, EndLine: 1, EndCharacter: 2, Light: "not a color", Dark: "#445566"},
	})
	if len(unordered.spans) != 1 || unordered.spans[0].start != 3 {
		t.Fatalf("an out-of-order range or a malformed color was kept: %+v", unordered.spans)
	}
}

// An edit moves the colors after it and drops only the ones it touches, so a rainbow keeps its
// colors while the provider computes the next answer. Undo and redo move them back and forth.
func TestColorDecorationsFollowEditsUndoAndRedo(t *testing.T) {
	v := newTestView(t, "(a) [bc]")
	color := func(start, end int) ColorDecoration {
		return ColorDecoration{StartLine: 0, StartCharacter: start, EndLine: 0, EndCharacter: end, Light: "#112233", Dark: "#445566"}
	}
	prepared := PrepareColorDecorations(v.TextSnapshot(), []ColorDecoration{color(0, 1), color(2, 3), color(4, 5), color(5, 7), color(7, 8)})
	v.SetPreparedColorDecorations(prepared)
	v.edit(0, 0, "xy", editOther)
	requireColorSpans(t, v, "insertion before every span", [2]int{2, 3}, [2]int{4, 5}, [2]int{6, 7}, [2]int{7, 9}, [2]int{9, 10})
	if v.SetPreparedColorDecorations(prepared) {
		t.Fatal("colors prepared for the old text were accepted")
	}
	if !v.Undo() {
		t.Fatal("nothing to undo")
	}
	requireColorSpans(t, v, "undo", [2]int{0, 1}, [2]int{2, 3}, [2]int{4, 5}, [2]int{5, 7}, [2]int{7, 8})
	if !v.Redo() {
		t.Fatal("nothing to redo")
	}
	requireColorSpans(t, v, "redo", [2]int{2, 3}, [2]int{4, 5}, [2]int{6, 7}, [2]int{7, 9}, [2]int{9, 10})
	// Typing at the end of a span or at the start of the next keeps both; typing inside one cuts it.
	v.edit(3, 3, "z", editOther)
	requireColorSpans(t, v, "insertion between two spans", [2]int{2, 3}, [2]int{5, 6}, [2]int{7, 8}, [2]int{8, 10}, [2]int{10, 11})
	v.edit(9, 9, "q", editOther)
	requireColorSpans(t, v, "insertion inside a span", [2]int{2, 3}, [2]int{5, 6}, [2]int{7, 8}, [2]int{11, 12})
	// Deleting a bracket drops its color and moves the rest back.
	v.edit(5, 6, "", editOther)
	requireColorSpans(t, v, "deleted span", [2]int{2, 3}, [2]int{6, 7}, [2]int{10, 11})
	v.edit(0, v.text.Len(), "", editOther)
	if v.decor.colors != nil || v.decor.colorPalette != nil {
		t.Fatal("deleting every colored character kept the palette")
	}
}

// A prepared replacement, such as formatting, moves the colors outside what it changed; a reload
// from disk replaces the whole text and clears them until the provider answers for it.
func TestColorDecorationsFollowPreparedEditsAndClearOnReload(t *testing.T) {
	v := newTestView(t, "f(x) g(y)")
	color := func(start, end int) ColorDecoration {
		return ColorDecoration{StartLine: 0, StartCharacter: start, EndLine: 0, EndCharacter: end, Light: "#112233", Dark: "#445566"}
	}
	v.SetPreparedColorDecorations(PrepareColorDecorations(v.TextSnapshot(), []ColorDecoration{color(1, 2), color(3, 4), color(6, 7), color(8, 9)}))
	prepared, err := PrepareEdits(v.TextSnapshot(), v.SavedSnapshot(), []TextEdit{{Range{4, 5}, "\n\t"}})
	if err != nil {
		t.Fatal(err)
	}
	if !v.ApplyPreparedEdit(prepared) {
		t.Fatal("the prepared edit was refused")
	}
	requireColorSpans(t, v, "prepared edit", [2]int{1, 2}, [2]int{3, 4}, [2]int{7, 8}, [2]int{9, 10})
	clean := newTestView(t, "f(x)")
	clean.SetPreparedColorDecorations(PrepareColorDecorations(clean.TextSnapshot(), []ColorDecoration{color(1, 2), color(3, 4)}))
	if !clean.Reload(Prepare([]byte("other(text)"))) {
		t.Fatal("reload was refused")
	}
	if len(clean.decor.colors) != 0 {
		t.Fatal("reload kept the colors of the replaced text")
	}
}

func TestColorDecorationPaintDoesNotAllocate(t *testing.T) {
	v := newTestView(t, "first second\nthird fourth")
	v.hl.Close()
	v.SetPreparedColorDecorations(PrepareColorDecorations(v.TextSnapshot(), []ColorDecoration{
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 5, Light: "#112233", Dark: "#445566"},
		{StartLine: 1, StartCharacter: 6, EndLine: 1, EndCharacter: 12, Light: "#445566", Dark: "#112233"},
	}))
	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 220}
	paint := func() { canvas.Reset(); v.Paint(canvas, area, Look{}) }
	paint()
	if allocs := testing.AllocsPerRun(20, paint); allocs != 0 {
		t.Fatalf("warm decoration paint allocated %v times", allocs)
	}
}
