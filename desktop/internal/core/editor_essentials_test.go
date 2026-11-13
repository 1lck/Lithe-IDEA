package core

import (
	"context"
	"errors"
	"testing"
)

func TestEditorFindBorrowsUnicodeSourceAndPlansReplacements(t *testing.T) {
	c := NewClient()
	replacement := "${1}!"
	got, err := c.FindEditorText(context.Background(), []byte("😀 αβ\nαβ"), EditorFindRequest{Query: "(αβ)", Regex: true, Replacement: &replacement})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Matches) != 2 || got.Matches[0].Start != 5 || got.Matches[1].Start != 10 || len(got.Edits) != 2 || got.Edits[0].Text != "αβ!" {
		t.Fatalf("unexpected Unicode plan: %+v", got)
	}
	_, err = c.FindEditorText(context.Background(), []byte("secret"), EditorFindRequest{Query: "[", Regex: true})
	var failure *Error
	if !errors.As(err, &failure) || failure.Details != "invalid_pattern" {
		t.Fatalf("invalid regex: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = c.FindEditorText(ctx, []byte("x"), EditorFindRequest{Query: "x"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled search: %v", err)
	}
}

func TestEditorEssentialsResolveDefaultsAndKeepIndependentSchemes(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	prefs, err := c.ResolveEditorPreferences(ctx, EditorStoredPreferences{})
	if err != nil {
		t.Fatal(err)
	}
	if !prefs.LineNumbers || !prefs.CursorBlink || prefs.CursorStyle != "line" || prefs.AutoSaveDelayMilliseconds != 1500 {
		t.Fatalf("preferences: %+v", prefs)
	}
	state, err := c.ReduceKeymapSchemes(ctx, KeymapSchemeRequest{Current: map[string][]string{"search.files": {"meta+f"}}})
	if err != nil {
		t.Fatal(err)
	}
	cloned, err := c.ReduceKeymapSchemes(ctx, KeymapSchemeRequest{State: state.State, Operation: "saveAs", ID: "mine", Name: "Mine"})
	if err != nil {
		t.Fatal(err)
	}
	if cloned.State.Active != "mine" || len(cloned.State.Schemes) != 2 || cloned.Bindings["search.files"][0] != "meta+f" {
		t.Fatalf("scheme: %+v", cloned)
	}
	recent, err := c.ReduceEditorRecent(ctx, EditorRecentRequest{Event: &EditorRecentEvent{Kind: "edited", Path: "src/a.go", Name: "a.go", Line: 2}})
	if err != nil || len(recent.Results) != 1 || recent.Results[0].Line != 2 {
		t.Fatalf("recent: %+v %v", recent, err)
	}
	decision, err := c.DecideEditorRecovery(ctx, EditorRecoveryRequest{BaseHash: "old"})
	if err != nil || decision.Action != "restoreConflict" {
		t.Fatalf("recovery: %+v %v", decision, err)
	}
}
