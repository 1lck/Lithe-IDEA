package ai

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestInlineContextNeverSplitsACharacter(t *testing.T) {
	text := []byte(strings.Repeat("é", InlineEditWindow) + "SEL" + strings.Repeat("世", InlineEditWindow))
	start := len(strings.Repeat("é", InlineEditWindow))
	before, after := InlineContext(text, start, start+3)
	if !utf8.ValidString(before) || !utf8.ValidString(after) {
		t.Fatal("the context splits a character")
	}
	if len([]rune(before)) < 12000 || len([]rune(after)) < 12000 {
		t.Fatalf("context is shorter than Core keeps: %d, %d", len([]rune(before)), len([]rune(after)))
	}
}
