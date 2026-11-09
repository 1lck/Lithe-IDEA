package editorview

import (
	"strings"
	"testing"
)

func TestSemanticReplacementKeepsUnchangedTextOutOfEditAndUndo(t *testing.T) {
	before := "alpha\n" + strings.Repeat("unchanged line\n", 8000)
	after := "alphabet\n" + strings.Repeat("unchanged line\n", 8000)
	v := newTestView(t, before)
	var changes []Edit
	v.cfg.OnEdit = func(edit Edit) { changes = append(changes, edit) }
	change := PrepareTextChange(v.TextSnapshot(), after, len("alphabet"))
	if !v.ApplyTextChange(change) {
		t.Fatal("completion was refused")
	}
	if len(changes) != 1 {
		t.Fatalf("edit count = %d, want 1", len(changes))
	}
	if changes[0].StartLine != 0 || changes[0].StartColumn != 5 || changes[0].EndLine != 0 || changes[0].EndColumn != 5 || changes[0].Text != "bet" {
		t.Fatalf("completion reported unchanged document text: edits=%d, inserted bytes=%d", len(changes), len(changes[0].Text))
	}
	if v.contents() != after {
		t.Fatal("completion content differs")
	}
	v.Undo()
	if v.contents() != before {
		t.Fatal("undo lost original content")
	}
	v.Redo()
	if v.contents() != after {
		t.Fatal("redo lost completion")
	}
}
