package fontprefs

import (
	"encoding/json"
	"reflect"
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

// TestAssignSetsTheScopesGivenAndJoinsTheSameLook: assigning a look to some scopes takes them
// from the font that had them and leaves the others as they were; assigning the look another
// font has joins the two; the values are clamped; no scope or only unknown ones change nothing,
// and the argument is not changed.
func TestAssignSetsTheScopesGivenAndJoinsTheSameLook(t *testing.T) {
	fonts := []Font{{Family: "A", Size: 15, Scopes: Scopes}}

	split := Assign(fonts, []Scope{Output, Editor}, Font{Family: "B", Size: 2, LineSpacing: 9, Ligatures: true, Scopes: []Scope{Terminal}})
	want := []Font{
		{Family: "B", Size: MinSize, LineSpacing: MaxLineSpacing, Ligatures: true, Scopes: []Scope{Editor, Output}},
		{Family: "A", Size: 15, Scopes: []Scope{Terminal}},
	}
	if !reflect.DeepEqual(split, want) {
		t.Fatalf("split = %+v, want %+v", split, want)
	}

	joined := Assign(split, []Scope{Terminal}, split[0])
	if len(joined) != 1 || !slices.Equal(joined[0].Scopes, Scopes) || joined[0].Family != "B" {
		t.Fatalf("assigning the look of the first font to the terminal = %+v, want one font", joined)
	}
	if back := Assign(split, []Scope{Editor, Output}, Font{Family: "A", Size: 15}); !Equal(back, fonts) {
		t.Fatalf("assigning the terminal's look to the others = %+v, want %+v", back, fonts)
	}

	if got := Assign(split, nil, Font{Family: "C"}); !Equal(got, split) {
		t.Fatalf("no scope changed the list: %+v", got)
	}
	if got := Assign(split, []Scope{"unknown"}, Font{Family: "C"}); !Equal(got, split) {
		t.Fatalf("an unknown scope changed the list: %+v", got)
	}
	if len(fonts[0].Scopes) != len(Scopes) || fonts[0].Family != "A" {
		t.Fatalf("Assign changed its argument: %+v", fonts)
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
	fonts := Assign(Default(), []Scope{Terminal}, Font{Family: "Menlo", Size: DefaultSize, LineSpacing: 1.2})
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
