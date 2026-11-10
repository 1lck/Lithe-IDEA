package editorview

import (
	"errors"
	"testing"
)

func TestApplyEditsIsOneUndoStepAndReportsOneChange(t *testing.T) {
	v := newTestView(t, "alpha\nbeta\ngamma\n")
	var reported []Edit
	v.cfg.OnEdit = func(e Edit) { reported = append(reported, e) }
	a, _ := v.OffsetOf(0, 0)
	b, _ := v.OffsetOf(2, 5)
	if err := v.ApplyEdits([]TextEdit{{Range{a, a + 5}, "ALPHA"}, {Range{b, b}, "!"}}); err != nil {
		t.Fatal(err)
	}
	if got := v.contents(); got != "ALPHA\nbeta\ngamma!\n" {
		t.Fatalf("text = %q", got)
	}
	if len(v.undo) != 1 || len(reported) != 1 {
		t.Fatalf("undo steps %d, reported changes %d, want one each", len(v.undo), len(reported))
	}
	if !v.Undo() || v.contents() != "alpha\nbeta\ngamma\n" {
		t.Fatalf("undo = %q", v.contents())
	}
}

func TestApplyEditsRefusesBadRanges(t *testing.T) {
	v := newTestView(t, "a😀b")
	if err := v.ApplyEdits([]TextEdit{{Range{1, 5}, "x"}, {Range{0, 1}, "y"}}); !errors.Is(err, ErrOverlap) {
		t.Fatalf("out of order = %v", err)
	}
	if err := v.ApplyEdits([]TextEdit{{Range{2, 3}, "x"}}); !errors.Is(err, ErrPosition) {
		t.Fatalf("inside a character = %v", err)
	}
	if v.contents() != "a😀b" || len(v.undo) != 0 {
		t.Fatalf("a refused batch changed the view: %q", v.contents())
	}
}

func TestOffsetOfRefusesWhatByteOffsetClamps(t *testing.T) {
	v := newTestView(t, "a😀b\r\nxy")
	if off, err := v.OffsetOf(0, 3); err != nil || off != 5 {
		t.Fatalf("OffsetOf(0,3) = %d %v", off, err)
	}
	if _, err := v.OffsetOf(0, 2); !errors.Is(err, ErrPosition) {
		t.Fatalf("inside a surrogate pair = %v", err)
	}
	if _, err := v.OffsetOf(0, 5); !errors.Is(err, ErrPosition) {
		t.Fatalf("past the line, into its CRLF = %v", err)
	}
	if _, err := v.OffsetOf(2, 0); !errors.Is(err, ErrPosition) {
		t.Fatalf("past the last line = %v", err)
	}
	if v.LineEnding() != "crlf" {
		t.Fatal("line ending")
	}
}

func TestReadOnlyViewRefusesEdits(t *testing.T) {
	v := newTestView(t, "abc")
	v.SetReadOnly(true)
	if err := v.ApplyEdits([]TextEdit{{Range{0, 1}, "x"}}); !errors.Is(err, ErrReadOnly) {
		t.Fatal(err)
	}
	v.insert("zzz", editTyping)
	if v.contents() != "abc" {
		t.Fatalf("typing changed a read-only view: %q", v.contents())
	}
}
