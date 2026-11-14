package workbench

import (
	"errors"
	"testing"
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

func TestInlineEditCodeIsExtractedFromCoreErrors(t *testing.T) {
	err := errors.New("lithe core: ai.inlineEdit.plan: AI_INLINE_EDIT_MODEL_MISSING (invalid_request)")
	if got := inlineEditCode.FindString(err.Error()); got != "AI_INLINE_EDIT_MODEL_MISSING" {
		t.Fatalf("code = %q", got)
	}
}
