package editorview

import (
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

func TestColorDecorationsConvertUTF16OnceAndClearAcrossEdits(t *testing.T) {
	v := newTestView(t, "😀a\r\n界b")
	decorations := []ColorDecoration{
		{StartLine: 0, StartCharacter: 2, EndLine: 0, EndCharacter: 3, Light: "#112233", Dark: "#445566"},
		{StartLine: 1, StartCharacter: 1, EndLine: 1, EndCharacter: 2, Light: "#112233", Dark: "#445566"},
	}
	prepared := PrepareColorDecorations(v.TextSnapshot(), decorations)
	if len(prepared.spans) != 2 || prepared.spans[0].start != len("😀") || prepared.spans[1].start != len("界") {
		t.Fatalf("UTF-16 columns did not become per-line UTF-8 offsets: %+v", prepared.spans)
	}
	v.SetPreparedColorDecorations(prepared)
	v.edit(0, 0, "x", editOther)
	if len(v.decor.colors) != 0 || v.SetPreparedColorDecorations(prepared) {
		t.Fatal("edit kept or accepted stale offsets")
	}
	v.SetPreparedColorDecorations(PrepareColorDecorations(v.TextSnapshot(), []ColorDecoration{{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 1, Light: "#112233", Dark: "#445566"}}))
	if !v.Undo() || len(v.decor.colors) != 0 {
		t.Fatal("undo retained the edited document's colors")
	}
	v.SetPreparedColorDecorations(prepared)
	if !v.Redo() || len(v.decor.colors) != 0 {
		t.Fatal("redo retained old colors")
	}
	bad := PrepareColorDecorations(rope.FromString("😀"), []ColorDecoration{{StartLine: 0, StartCharacter: 1, EndLine: 0, EndCharacter: 2, Light: "#112233", Dark: "#445566"}})
	if len(bad.spans) != 0 {
		t.Fatal("a range cut a surrogate pair")
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
