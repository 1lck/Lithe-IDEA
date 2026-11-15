package termview

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

// blockGesture drags from down to the last move with modifiers held and releases there,
// the way a block selection is drawn.
func blockGesture(rig *fontRig, modifiers gfx.Modifiers, down [2]int, moves ...[2]int) {
	at := func(cell [2]int) (float32, float32) {
		layout := rig.view.layout
		return layout.left + (float32(cell[1])+0.5)*rig.view.cellW, layout.top + (float32(cell[0])+0.5)*rig.view.rowH
	}
	hit := rig.view.cfg.HitID
	x, y := at(down)
	rig.view.Pointer(gfx.PointerEvent{
		Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 1, Modifiers: modifiers,
		Target: hit, X: x, Y: y,
	})
	last := down
	for _, cell := range moves {
		x, y = at(cell)
		rig.view.Pointer(gfx.PointerEvent{
			Kind: gfx.PointerMove, Button: gfx.PointerButtonPrimary, Captured: true, Modifiers: modifiers,
			Target: hit, X: x, Y: y,
		})
		last = cell
	}
	x, y = at(last)
	rig.view.Pointer(gfx.PointerEvent{
		Kind: gfx.PointerUp, Button: gfx.PointerButtonPrimary, Captured: true, Modifiers: modifiers,
		Target: hit, X: x, Y: y,
	})
}

const blockTable = "name    value\r\nalpha   1234\r\nbeta    5678\r\n"

// Dragging with the block chord held selects the rectangle under the drag: copying it
// gives the column alone, and painting marks the same columns on each of its rows.
func TestBlockDragSelectsTheRectangleAndCopiesIt(t *testing.T) {
	rig := newFontRig(t)
	output(rig.view, &rig.shell.fakeShell, blockTable)
	rig.paint()
	blockGesture(rig, blockSelectionModifiers(), [2]int{0, 8}, [2]int{1, 10}, [2]int{2, 12})

	if got := rig.view.SelectionText(); got != "value\n1234\n5678" {
		t.Fatalf("block drag copied %q", got)
	}
	cols, _ := rig.view.screen.Size()
	for row := 0; row < 3; row++ {
		from, to, selected := rig.view.selection.span(rig.view.screen.LineNumber(row), rig.view.screen.Row(row), cols)
		if !selected || from != 8 || to != 13 {
			t.Fatalf("row %d span %d..%d, %v", row, from, to, selected)
		}
	}
	if _, _, selected := rig.view.selection.span(rig.view.screen.LineNumber(3), rig.view.screen.Row(3), cols); selected {
		t.Fatal("a row below the rectangle is painted as selected")
	}

	// A plain drag afterwards selects text again, not a rectangle.
	blockGesture(rig, 0, [2]int{0, 8}, [2]int{1, 3})
	if rig.view.selection.block {
		t.Fatal("a plain drag kept the block mode")
	}
	if got := rig.view.SelectionText(); got != "value\nalph" {
		t.Fatalf("plain drag after a block selected %q", got)
	}
}

// The chord without a drag selects nothing and leaves no block mode behind.
func TestBlockPressWithoutADragStaysAClick(t *testing.T) {
	rig := newFontRig(t)
	blockGesture(rig, blockSelectionModifiers(), [2]int{1, 2})
	if rig.view.selection.selected || rig.view.selection.dragging || rig.view.selection.block {
		t.Fatalf("click left %+v", rig.view.selection)
	}
}

// A program that asked for the mouse keeps the chord's press; Shift hands it back to the
// terminal, and the chord then selects the rectangle.
func TestBlockSelectionYieldsToProgramsUsingTheMouse(t *testing.T) {
	rig := newFontRig(t)
	output(rig.view, &rig.shell.fakeShell, "\x1b[?1000h"+blockTable)
	rig.paint()

	blockGesture(rig, blockSelectionModifiers(), [2]int{0, 8}, [2]int{2, 12})
	if rig.view.selection.selected {
		t.Fatal("the terminal took a drag the program had the mouse for")
	}
	if len(rig.shell.input) == 0 {
		t.Fatal("the program using the mouse received nothing")
	}
	blockGesture(rig, gfx.ModifierShift|blockSelectionModifiers(), [2]int{0, 8}, [2]int{2, 12})
	if got := rig.view.SelectionText(); got != "value\n1234\n5678" {
		t.Fatalf("Shift+block drag selected %q", got)
	}
}
