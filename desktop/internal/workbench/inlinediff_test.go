package workbench

import (
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestLineDiffMarksOnlyWhatChanged(t *testing.T) {
	got := lineDiff("a\nb\nc", "a\nB\nc\nd")
	want := []diffLine{{diffSame, "a"}, {diffRemoved, "b"}, {diffAdded, "B"}, {diffSame, "c"}, {diffAdded, "d"}}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("line %d = %v, want %v", i, got[i], want[i])
		}
	}
	if d := lineDiff("x", ""); len(d) != 1 || d[0].kind != diffRemoved {
		t.Fatalf("empty replacement = %v", d)
	}
}

func TestInlineContextNeverSplitsACharacter(t *testing.T) {
	text := []byte(strings.Repeat("é", inlineEditWindow) + "SEL" + strings.Repeat("世", inlineEditWindow))
	start := len(strings.Repeat("é", inlineEditWindow))
	before, after := inlineContext(text, start, start+3)
	if !utf8.ValidString(before) || !utf8.ValidString(after) {
		t.Fatal("the context splits a character")
	}
	if len([]rune(before)) < 12000 || len([]rune(after)) < 12000 {
		t.Fatalf("context is shorter than Core keeps: %d, %d", len([]rune(before)), len([]rune(after)))
	}
}

func TestInlineEditCodeIsExtractedFromCoreErrors(t *testing.T) {
	err := errors.New("lithe core: ai.inlineEdit.plan: AI_INLINE_EDIT_MODEL_MISSING (invalid_request)")
	if got := inlineEditCode.FindString(err.Error()); got != "AI_INLINE_EDIT_MODEL_MISSING" {
		t.Fatalf("code = %q", got)
	}
}
