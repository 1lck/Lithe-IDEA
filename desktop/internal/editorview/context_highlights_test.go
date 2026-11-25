package editorview

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestBracketPairUsesEffectiveVimSelection(t *testing.T) {
	v := newTestView(t, "(name)")
	v.SetBracketMatches([]BracketMatch{{Offset: 0, Mate: 5}, {Offset: 5, Mate: 0}})
	v.SetVimMode(true)
	if pair := v.caretBracketPair(v.Selection()); pair != [2]int{0, 5} {
		t.Fatalf("normal caret pair = %v", pair)
	}
	v.vim.mode = vimVisual
	if pair := v.caretBracketPair(v.Selection()); pair != [2]int{} {
		t.Fatalf("visual selection highlighted %v", pair)
	}
}

func TestSymbolHighlightsClearWhenVimSelectionEnds(t *testing.T) {
	v := newTestView(t, "x = x")
	v.SetVimMode(true)
	v.vim.mode = vimVisual
	v.SetSymbolHighlights([]Range{{Start: 4, End: 5}})
	canvas := new(gfx.Canvas)
	color := gfx.RGB24(0x102030)
	highlight := color
	highlight.Alpha *= 0.14
	hasHighlight := func() bool {
		canvas.Reset()
		v.Paint(canvas, gfx.Rect{Width: 440, Height: 100}, Look{Foreground: color})
		for _, rect := range canvas.Rectangles() {
			if rect.Color == highlight {
				return true
			}
		}
		return false
	}
	if !hasHighlight() {
		t.Fatal("single-character Vim selection did not paint its reference")
	}
	v.SetVimMode(false)
	if hasHighlight() {
		t.Fatal("reference highlight survived the end of the Vim selection")
	}
}
