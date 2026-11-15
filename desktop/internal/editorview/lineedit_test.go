package editorview

import "testing"

func TestLineEditWindowAndApply(t *testing.T) {
	v := New(Config{Content: Prepare([]byte("a\nb😀\nc\nd\ne"))})
	t.Cleanup(v.Close)
	// Select "😀" of line 1 (caret after it).
	offset := v.text.LineStart(1) + 1 + len("😀")
	v.SetSelection(offset, offset)
	in, ok := v.LineEditInput()
	if !ok {
		t.Fatal("window refused")
	}
	if in.Source != "a\nb😀\nc" || in.SelectionStart != 2+1+2 || in.SelectionLength != 0 {
		t.Fatalf("window = %q %d %d", in.Source, in.SelectionStart, in.SelectionLength)
	}
	// Move line 1 down: "a\nc\nb😀" with the caret at the end of the moved line.
	if !v.ApplyLineEdit(in, 2, 5, "c\nb😀", 7, 0) {
		t.Fatal("apply refused")
	}
	if got := v.text.String(); got != "a\nc\nb😀\nd\ne" {
		t.Fatalf("text = %q", got)
	}
	if _, caret := v.SelectionOffsets(); caret != len("a\nc\nb😀") {
		t.Fatalf("caret = %d", caret)
	}
	v.Undo()
	if got := v.text.String(); got != "a\nb😀\nc\nd\ne" {
		t.Fatalf("undo = %q", got)
	}
}

func TestLineEditRejectsStaleWindow(t *testing.T) {
	v := New(Config{Content: Prepare([]byte("a\nb"))})
	t.Cleanup(v.Close)
	in, _ := v.LineEditInput()
	v.insert("x", editOther)
	if v.ApplyLineEdit(in, 0, 1, "z", 0, 0) {
		t.Fatal("applied over a newer revision")
	}
}

func TestLineEditNeedsEditableView(t *testing.T) {
	v := New(Config{Content: Prepare([]byte("a"))})
	t.Cleanup(v.Close)
	v.SetReadOnly(true)
	if _, ok := v.LineEditInput(); ok {
		t.Fatal("window for a read-only view")
	}
}
