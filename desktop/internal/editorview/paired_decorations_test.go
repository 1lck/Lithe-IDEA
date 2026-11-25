package editorview

import (
	"slices"
	"testing"
)

func TestPairedDocumentDecorationsOwnMutableForegroundSpans(t *testing.T) {
	source := newTestView(t, "{\n    value()\n}")
	source.SetPreparedColorDecorations(PrepareColorDecorations(source.TextSnapshot(), []ColorDecoration{
		{StartLine: 1, StartCharacter: 4, EndLine: 1, EndCharacter: 9, Light: "#123456", Dark: "#654321"},
	}))
	source.SetBracketMatches([]BracketMatch{{Offset: 0, Mate: 14}, {Offset: 14, Mate: 0}})
	source.SetIndentGuideScopes(PrepareIndentGuideScopes(source.TextSnapshot(), []IndentGuideScope{{Open: 0, Close: 14}}))
	paired := New(Config{Content: source.CopyContent()})
	t.Cleanup(paired.Close)
	if !paired.CopyDocumentDecorationsFrom(source) {
		t.Fatal("second view rejected the shared snapshot")
	}
	if !slices.Equal(paired.bracketMatches, source.bracketMatches) || len(paired.indentGuideScopes) != len(source.indentGuideScopes) {
		t.Fatal("second view lost the matching and scope geometry")
	}
	for _, view := range []*View{source, paired} {
		if !view.ApplyEdit(Edit{Text: "\n"}, false) {
			t.Fatal("could not apply a mirrored insertion")
		}
	}
	for _, view := range []*View{source, paired} {
		if got := view.decor.colors; len(got) != 1 || got[0].start != 7 || got[0].end != 12 {
			t.Fatalf("mirrored insertion moved a color more than once: %+v", got)
		}
	}
	if source.text.Same(paired.text) {
		t.Fatal("test needs independently mirrored rope snapshots")
	}
	if paired.CopyDocumentDecorationsFrom(source) {
		t.Fatal("window-thread copy accepted a snapshot that needs a worker comparison")
	}
}

func TestPairedPreparedDecorationsAcceptEqualSnapshotsAndRejectStale(t *testing.T) {
	source := newTestView(t, "{\n    value()\n}")
	paired := newTestView(t, "{\n    value()\n}")
	prepared := PrepareColorDecorations(source.TextSnapshot(), []ColorDecoration{
		{StartLine: 1, StartCharacter: 4, EndLine: 1, EndCharacter: 9, Light: "#123456", Dark: "#654321"},
	})
	colors := prepared.CloneFor(paired.TextSnapshot())
	scopes := PrepareIndentGuideScopes(source.TextSnapshot(), []IndentGuideScope{{Open: 0, Close: 14}}).ForSnapshot(paired.TextSnapshot())
	if !source.SetPreparedColorDecorations(prepared) || !paired.SetPreparedColorDecorations(colors) {
		t.Fatal("equal mirrored snapshots rejected prepared foregrounds")
	}
	paired.SetIndentGuideScopes(scopes)
	if len(paired.indentGuideScopes) != 1 {
		t.Fatal("equal mirrored snapshot rejected scope geometry")
	}
	if !paired.ApplyEdit(Edit{Text: "\n"}, false) {
		t.Fatal("could not edit the target")
	}
	if source.decor.colors[0].start != 6 {
		t.Fatal("editing the second view mutated the source's foreground spans")
	}
	if paired.SetPreparedColorDecorations(colors) {
		t.Fatal("late foreground result replaced the newer target snapshot")
	}
	paired.SetIndentGuideScopes(scopes)
	if paired.indentGuideRevision == paired.Revision() {
		t.Fatal("late scope geometry was applied to the newer target snapshot")
	}
	mismatched := prepared.CloneFor(paired.TextSnapshot())
	if paired.SetPreparedColorDecorations(mismatched) {
		t.Fatal("foreground coordinates were accepted for different text")
	}
}
