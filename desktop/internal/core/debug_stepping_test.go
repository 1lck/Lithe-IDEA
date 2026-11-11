package core

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"
)

// Core trims, sorts and de-duplicates a stepping policy and rejects one it cannot pass on.
func TestNormalizeSteppingFiltersThroughCore(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := client.NormalizeSteppingFilters(ctx, "java", DebugSteppingFilters{
		ClassNameFilters: []string{" sun.* ", "java.*", "sun.*", ""}, SkipConstructors: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got.ClassNameFilters, []string{"java.*", "sun.*"}) || !got.SkipConstructors || got.SkipSynthetics {
		t.Fatalf("normalized = %+v", got)
	}
	empty, err := client.NormalizeSteppingFilters(ctx, "java", DebugSteppingFilters{})
	if err != nil || empty.ClassNameFilters == nil || len(empty.ClassNameFilters) != 0 {
		t.Fatalf("an empty policy = %+v, %v", empty, err)
	}
	if _, err := client.NormalizeSteppingFilters(ctx, "java", DebugSteppingFilters{ClassNameFilters: []string{"a\nb"}}); err == nil {
		t.Fatal("Core accepted a pattern spanning two lines")
	}
}

func TestDeclaredSteppingFiltersReadsTheDeclaration(t *testing.T) {
	features := json.RawMessage(`{"stepFilters":{"argument":"stepFilters"}}`)
	defaults := json.RawMessage(`{"stepFilters":{"classNameFilters":["java.*"],"skipSynthetics":true,"hideFilteredStackFrames":true}}`)
	got, ok := DeclaredSteppingFilters(features, defaults)
	if !ok || !slices.Equal(got.ClassNameFilters, []string{"java.*"}) || !got.SkipSynthetics || !got.HideFilteredStackFrames {
		t.Fatalf("declared = %+v, %v", got, ok)
	}
	if got, ok := DeclaredSteppingFilters(features, nil); !ok || len(got.ClassNameFilters) != 0 {
		t.Fatalf("without defaults = %+v, %v", got, ok)
	}
	for _, without := range []string{``, `{}`, `{"hotCodeReplace":{"request":"x"}}`, `{"stepFilters":{}}`} {
		if _, ok := DeclaredSteppingFilters(json.RawMessage(without), defaults); ok {
			t.Fatalf("%q declares stepping filters", without)
		}
	}
}
