package editorview

import "testing"

func TestPreparedBulkEditIsAtomicUndoableAndRejectsStaleText(t *testing.T) {
	v := newTestView(t, "a 😀 a")
	prepared, err := PrepareEdits(v.TextSnapshot(), v.SavedSnapshot(), []TextEdit{{Range{0, 1}, "ALPHA"}, {Range{7, 8}, "β"}})
	if err != nil {
		t.Fatal(err)
	}
	if !v.ApplyPreparedEdit(prepared) || v.contents() != "ALPHA 😀 β" {
		t.Fatalf("prepared content: %q", v.contents())
	}
	v.Undo()
	if v.contents() != "a 😀 a" {
		t.Fatalf("undo: %q", v.contents())
	}
	v.typeText("x")
	if v.ApplyPreparedEdit(prepared) {
		t.Fatal("stale edit changed the document")
	}
}

func TestPreparedBulkEditRejectsChangedSavedBaselineAndKeepsNoOpOutOfUndo(t *testing.T) {
	v := newTestView(t, "one")
	v.SetSelection(3, 3)
	v.typeText("!")
	before := v.TextSnapshot()
	prepared, err := PrepareEdits(before, v.SavedSnapshot(), []TextEdit{{Range{0, 3}, "two"}})
	if err != nil {
		t.Fatal(err)
	}
	v.MarkSaved(before)
	if v.ApplyPreparedEdit(prepared) || v.contents() != "one!" {
		t.Fatal("saved baseline race was not rejected")
	}
	noOp, err := PrepareEdits(before, v.SavedSnapshot(), []TextEdit{{Range{0, 3}, "one"}})
	if err != nil {
		t.Fatal(err)
	}
	count := len(v.undo)
	if !v.ApplyPreparedEdit(noOp) || len(v.undo) != count || v.Dirty() {
		t.Fatal("identical replacement added undo or changed dirty state")
	}
}
