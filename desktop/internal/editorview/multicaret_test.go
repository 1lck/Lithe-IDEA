package editorview

import (
	"testing"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// Typing, Backspace and Undo act at every caret, and one Undo takes back an edit made at all.
func TestTypingAtEveryCaretIsOneUndoStep(t *testing.T) {
	v := newTestView(t, "ab\nab\nab")
	v.anchor, v.caret = 1, 1
	v.toggleCaret(4)
	v.toggleCaret(7)
	if !v.HasExtraCarets() || len(v.extra) != 2 {
		t.Fatalf("extra = %v", v.extra)
	}
	v.applyText(app.TextEvent{Kind: app.TextInsert, Text: "X"})
	if got := v.contents(); got != "aXb\naXb\naXb" {
		t.Fatalf("after typing %q", got)
	}
	v.key(gfx.KeyEvent{Key: gfx.KeyBackspace, Target: v.cfg.HitID})
	v.key(gfx.KeyEvent{Key: gfx.KeyBackspace, Target: v.cfg.HitID})
	if got := v.contents(); got != "b\nb\nb" {
		t.Fatalf("after backspaces %q", got)
	}
	v.Undo()
	v.Undo()
	if got := v.contents(); got != "aXb\naXb\naXb" || len(v.extra) != 2 {
		t.Fatalf("after undo %q, extra %v", got, v.extra)
	}
	v.Undo()
	if got := v.contents(); got != "ab\nab\nab" {
		t.Fatalf("after undo %q", got)
	}
}

// Add Selection for Next Occurrence selects the word, then each next occurrence; cutting cuts all.
func TestNextOccurrenceSelectsEachMatch(t *testing.T) {
	v := newTestView(t, "foo bar foo baz foo")
	v.anchor, v.caret = 1, 1
	v.AddNextOccurrence()
	v.AddNextOccurrence()
	v.AddNextOccurrence()
	if len(v.extra) != 2 || v.selectedTexts() != "foo\nfoo\nfoo" {
		t.Fatalf("extra %v, texts %q", v.extra, v.selectedTexts())
	}
	v.insertAll("q", editTyping, false)
	if got := v.contents(); got != "q bar q baz q" {
		t.Fatalf("got %q", got)
	}
	v.ClearExtraCarets()
	if v.HasExtraCarets() {
		t.Fatal("extra carets after clearing")
	}
}

// A paste of as many lines as carets gives each caret its line.
func TestPasteDistributesLinesOverCarets(t *testing.T) {
	v := newTestView(t, "a\nb")
	v.anchor, v.caret = 1, 1
	v.toggleCaret(3)
	v.insertAll("1\n2\n", editOther, true)
	if got := v.contents(); got != "a1\nb2" {
		t.Fatalf("got %q", got)
	}
}
