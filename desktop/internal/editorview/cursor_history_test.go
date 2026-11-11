package editorview

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

// shortcut presses a command chord of the editor.
func (v *View) shortcut(text string, shift bool) {
	mods := commandKey()
	if shift {
		mods |= gfx.ModifierShift
	}
	v.Shortcut(gfx.KeyEvent{Text: text, Modifiers: mods, Target: v.cfg.HitID})
}

func (v *View) caretAt() int {
	_, caret := v.SelectionOffsets()
	return caret
}

// Undo takes back the last keyboard move before it takes back text, once.
func TestUndoRestoresTheCursorBeforeUndoingText(t *testing.T) {
	v := newTestView(t, "one\ntwo\nthree\n")
	v.typeText("abc")
	v.press(gfx.KeyDown, 0)
	v.press(gfx.KeyDown, 0)
	if got := v.caretAt(); got != 14 {
		t.Fatalf("caret after two downs = %d", got)
	}

	v.shortcut("z", false)
	if got := v.caretAt(); got != 10 || v.contents() != "abcone\ntwo\nthree\n" {
		t.Fatalf("first undo = caret %d text %q, want the previous line and the text kept", got, v.contents())
	}
	v.shortcut("z", false)
	if got := v.contents(); got != "one\ntwo\nthree\n" {
		t.Fatalf("second undo = %q, want the typing taken back", got)
	}

	// Redo restores the typing; the cursor history of the undone move is gone.
	v.shortcut("z", true)
	if got := v.contents(); got != "abcone\ntwo\nthree\n" {
		t.Fatalf("redo = %q", got)
	}
	// A text redo restores the selection it had when the text was undone.
	if got := v.caretAt(); got != 10 {
		t.Fatalf("redo caret = %d, want the pre-undo selection", got)
	}
}

// Ctrl+U and Ctrl+Shift+U walk the cursor history on their own.
func TestCursorUndoAndRedoWalkMovements(t *testing.T) {
	v := newTestView(t, "one\ntwo\nthree\n")
	v.typeText("abc")
	v.press(gfx.KeyDown, 0)
	v.press(gfx.KeyDown, 0)
	v.shortcut("u", false)
	if got := v.caretAt(); got != 10 {
		t.Fatalf("cursor undo = %d, want 10", got)
	}
	v.shortcut("u", false)
	if got := v.caretAt(); got != 3 {
		t.Fatalf("second cursor undo = %d, want the typing position", got)
	}
	v.shortcut("u", true)
	if got := v.caretAt(); got != 10 {
		t.Fatalf("cursor redo = %d, want 10", got)
	}
	if got := v.contents(); got != "abcone\ntwo\nthree\n" {
		t.Fatalf("cursor history changed the text: %q", got)
	}

	// A new move makes the redo chain stale.
	v.shortcut("u", false)
	v.press(gfx.KeyLeft, 0)
	if v.CursorRedo() {
		t.Fatal("a keyboard move after a cursor undo kept the redo chain")
	}
}

// Text and API selection changes clear the history.
func TestCursorHistoryClearsOnEditsAndApiMoves(t *testing.T) {
	v := newTestView(t, "one\ntwo\n")
	v.press(gfx.KeyDown, 0)
	v.typeText("x")
	if v.CursorUndoPending() {
		t.Fatal("typing kept a pending cursor move")
	}
	if v.CursorUndo() {
		t.Fatal("typing kept a cursor history")
	}
	v.press(gfx.KeyDown, 0)
	v.press(gfx.KeyUp, 0)
	if !v.CursorUndoPending() {
		t.Fatal("a keyboard move did not become pending")
	}
	if !v.SetSelection(0, 0) {
		t.Fatal("SetSelection refused a valid selection")
	}
	if v.CursorUndoPending() {
		t.Fatal("an API selection change kept the cursor history")
	}
}
