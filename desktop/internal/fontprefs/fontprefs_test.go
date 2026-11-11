package fontprefs

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestDefaultCoversEveryScopeWithOneFont(t *testing.T) {
	fonts := Default()
	if len(fonts) != 1 || !slices.Equal(fonts[0].Scopes, Scopes) {
		t.Fatalf("Default() = %+v, want one font for %v", fonts, Scopes)
	}
	if !Equal(Normalize(nil), fonts) || !Equal(Normalize([]Font{}), fonts) {
		t.Fatalf("Normalize of an empty list = %+v, want the default", Normalize(nil))
	}
}

func TestNormalizeGivesEveryScopeExactlyOneFont(t *testing.T) {
	fonts := Normalize([]Font{
		{Family: " Menlo ", Size: 200, LineSpacing: 1.44, Scopes: []Scope{Output, Editor, "unknown"}},
		{Family: "Fira Code", Size: 0, LineSpacing: -1, Scopes: []Scope{Editor}},
		{Family: "Ignored", Scopes: nil},
	})
	if len(fonts) != 2 {
		t.Fatalf("Normalize = %+v, want two fonts", fonts)
	}
	first := fonts[0]
	if first.Family != "Menlo" || first.Size != MaxSize || first.LineSpacing != 1.4 || !slices.Equal(first.Scopes, []Scope{Editor, Output}) {
		t.Fatalf("first font = %+v", first)
	}
	// The terminal, which no stored font named, gets a default font of its own, and the
	// second stored font, whose only scope the first took, is dropped.
	second := fonts[1]
	if second.Family != "" || second.Size != DefaultSize || second.LineSpacing != 0 || !slices.Equal(second.Scopes, []Scope{Terminal}) {
		t.Fatalf("second font = %+v", second)
	}
}

func TestNormalizeSortsFontsByTheirFirstScope(t *testing.T) {
	fonts := Normalize([]Font{
		{Family: "B", Scopes: []Scope{Output}},
		{Family: "A", Scopes: []Scope{Terminal, Editor}},
	})
	if fonts[0].Family != "A" || fonts[1].Family != "B" {
		t.Fatalf("Normalize = %+v, want the font with the editor first", fonts)
	}
}

func TestForResolvesAutomaticLineSpacingPerScope(t *testing.T) {
	fonts := []Font{{Family: "JetBrains Mono", Size: 14, Ligatures: true, Scopes: Scopes}}
	for _, scope := range Scopes {
		got := For(fonts, scope)
		if got.Family != "JetBrains Mono" || got.Size != 14 || !got.Ligatures || !got.Auto || got.LineSpacing != AutoLineSpacing(scope) {
			t.Fatalf("For(%s) = %+v", scope, got)
		}
	}
	fonts[0].LineSpacing = 1.6
	if got := For(fonts, Terminal); got.Auto || got.LineSpacing != 1.6 {
		t.Fatalf("For(terminal) with a set spacing = %+v", got)
	}
}

func TestSetScopeSplitsAndMoves(t *testing.T) {
	fonts := []Font{{Family: "A", Size: 15, Scopes: Scopes}}

	// Unchecking the terminal gives it a font of its own that starts as a copy.
	split := SetScope(fonts, 0, Terminal, false)
	if len(split) != 2 || !slices.Equal(split[0].Scopes, []Scope{Editor, Output}) || !slices.Equal(split[1].Scopes, []Scope{Terminal}) {
		t.Fatalf("split = %+v", split)
	}
	if split[1].Family != "A" || split[1].Size != 15 {
		t.Fatalf("the split font = %+v, want a copy of the values", split[1])
	}

	// A font keeps its last scope.
	if kept := SetScope(split, 1, Terminal, false); !Equal(kept, split) {
		t.Fatalf("unchecking the last scope changed the list: %+v", kept)
	}

	// Checking the terminal in the first font moves it back and drops the emptied font.
	merged := SetScope(split, 0, Terminal, true)
	if len(merged) != 1 || !slices.Equal(merged[0].Scopes, Scopes) || merged[0].Family != "A" {
		t.Fatalf("merged = %+v", merged)
	}

	// Out of range and unknown scopes change nothing.
	if got := SetScope(split, 5, Editor, true); !Equal(got, split) {
		t.Fatalf("an index out of range changed the list: %+v", got)
	}
	if got := SetScope(split, 0, "unknown", true); !Equal(got, split) {
		t.Fatalf("an unknown scope changed the list: %+v", got)
	}
	if len(fonts[0].Scopes) != len(Scopes) {
		t.Fatalf("SetScope changed its argument: %+v", fonts)
	}
}

func TestUpdateKeepsScopesAndClamps(t *testing.T) {
	fonts := []Font{{Scopes: []Scope{Editor}}, {Scopes: []Scope{Terminal, Output}}}
	got := Update(fonts, 1, func(f *Font) {
		f.Family = "Fira Code"
		f.Size = 2
		f.LineSpacing = 9
		f.Ligatures = true
		f.Scopes = nil
	})
	if got[1].Family != "Fira Code" || got[1].Size != MinSize || got[1].LineSpacing != MaxLineSpacing || !got[1].Ligatures {
		t.Fatalf("updated font = %+v", got[1])
	}
	if !slices.Equal(got[1].Scopes, []Scope{Terminal, Output}) {
		t.Fatalf("Update changed the scopes: %+v", got[1].Scopes)
	}
	if got[0].Family != "" {
		t.Fatalf("Update changed another font: %+v", got[0])
	}
}

func TestClampLineSpacingRoundsToAStep(t *testing.T) {
	cases := map[float32]float32{0: 0, -2: 0, 0.5: MinLineSpacing, 1.26: 1.3, 1.24: 1.2, 4: MaxLineSpacing}
	for in, want := range cases {
		if got := ClampLineSpacing(in); got != want {
			t.Fatalf("ClampLineSpacing(%v) = %v, want %v", in, got, want)
		}
	}
}

func TestFontsRoundTripThroughJSON(t *testing.T) {
	fonts := SetScope(Default(), 0, Terminal, false)
	fonts = Update(fonts, 1, func(f *Font) { f.Family = "Menlo"; f.LineSpacing = 1.2 })
	data, err := json.Marshal(fonts)
	if err != nil {
		t.Fatal(err)
	}
	var back []Font
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	if !Equal(back, fonts) {
		t.Fatalf("round trip = %+v, want %+v (json %s)", back, fonts, data)
	}
}
