package textmate

import (
	"fmt"
	"strings"
	"testing"
)

func parseTestGrammar(t *testing.T, source string) *RawGrammar {
	t.Helper()
	raw, err := ParseGrammar([]byte(source))
	if err != nil {
		t.Fatalf("ParseGrammar(%s): %v", source, err)
	}
	return raw
}

func TestParseGrammarMatchesKeysExactly(t *testing.T) {
	raw := parseTestGrammar(t, `{
		"scopeName": "source.a", "ScopeName": "source.b",
		"Patterns": [{"match": "x", "name": "wrong"}],
		"patterns": [{"MATCH": "x", "Name": "wrong", "match": "y", "name": "right", "comment": "a note"}],
		"Repository": {"r": {"match": "x"}}
	}`)
	if raw.ScopeName != "source.a" || raw.Repository != nil {
		t.Fatalf("scopeName %q, repository %v", raw.ScopeName, raw.Repository)
	}
	if len(raw.Patterns) != 1 || raw.Patterns[0].Match != "y" || raw.Patterns[0].Name != "right" {
		t.Fatalf("patterns %+v", raw.Patterns)
	}
}

func TestParseGrammarTakesTheLastOfARepeatedKey(t *testing.T) {
	raw := parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [{"match": "1"}], "patterns": [{"match": "2"}]}`)
	if len(raw.Patterns) != 1 || raw.Patterns[0].Match != "2" {
		t.Fatalf("patterns %+v", raw.Patterns)
	}
}

func TestParseGrammarLeavesOutNullRules(t *testing.T) {
	raw := parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [null, {"match": "x", "patterns": [null]}],
		"repository": {"r": null}}`)
	if len(raw.Patterns) != 1 || len(raw.Patterns[0].Patterns) != 0 || len(raw.Repository) != 0 {
		t.Fatalf("patterns %+v, repository %v", raw.Patterns, raw.Repository)
	}
}

func TestParseGrammarReadsCaptureGroups(t *testing.T) {
	raw := parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [{
		"match": "x",
		"captures": {
			"1": {"name": "canonical"}, "01": {"name": "padded"}, "+1": {"name": "signed"},
			"02": {"name": "padded"}, "+2": {"name": "signed"},
			"-0": {"name": "zero"}, "-1": {"name": "negative"}, "x": {"name": "note"},
			"3": null, "4096": {"name": "last"}, "4097": {"name": "past"}
		},
		"beginCaptures": [null, {"name": "first"}]
	}]}`)
	got := map[int]string{}
	for group, rule := range raw.Patterns[0].Captures {
		got[group] = rule.Name
	}
	// "02" sorts after "+2", so it wins group 2; the canonical "1" wins group 1 whatever the order.
	want := map[int]string{0: "zero", 1: "canonical", 2: "padded", MaxCaptureGroup: "last"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("captures %v, want %v", got, want)
	}
	begin := raw.Patterns[0].BeginCaptures
	if len(begin) != 1 || begin[1].Name != "first" {
		t.Fatalf("beginCaptures %v", begin)
	}
}

func TestParseGrammarBoundsCaptureArrays(t *testing.T) {
	groups := make([]string, MaxCaptureGroup+3)
	for i := range groups {
		groups[i] = "null"
	}
	groups[MaxCaptureGroup] = `{"name": "last"}`
	groups[MaxCaptureGroup+2] = `{"name": "past"}`
	raw := parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [{"match": "x", "captures": [`+strings.Join(groups, ",")+`]}]}`)
	captures := raw.Patterns[0].Captures
	if len(captures) != 1 || captures[MaxCaptureGroup].Name != "last" {
		t.Fatalf("captures %v", captures)
	}
	g, ok := registryOf(raw).Grammar("source.a")
	if !ok {
		t.Fatal("no grammar")
	}
	if tokens, _, _ := g.NewTokenizer().TokenizeLine(nil, []byte("x"), nil, 0); len(tokens) == 0 {
		t.Fatal("no tokens")
	}
}

func TestParseGrammarReadsFlags(t *testing.T) {
	for source, want := range map[string]bool{
		`true`: true, `1`: true, `"1"`: true, `"true"`: true,
		`false`: false, `0`: false, `"0"`: false, `"false"`: false, `""`: false, `null`: false,
	} {
		raw := parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [{"begin": "a", "end": "b", "applyEndPatternLast": `+source+`}]}`)
		if got := bool(raw.Patterns[0].ApplyEndPatternLast); got != want {
			t.Errorf("applyEndPatternLast %s = %v, want %v", source, got, want)
		}
	}
}

func TestParseGrammarRejectsWrongTypes(t *testing.T) {
	for source, path := range map[string]string{
		`[]`:                               "not a JSON object",
		`{"patterns": []}`:                 "no scopeName",
		`{"scopeName": 1, "patterns": []}`: "scopeName",
		`{"scopeName": "source.a", "patterns": {}}`:                                     "patterns",
		`{"scopeName": "source.a", "patterns": [1]}`:                                    "patterns[0]",
		`{"scopeName": "source.a", "patterns": [{"name": 1}]}`:                          "patterns[0].name",
		`{"scopeName": "source.a", "repository": {"r": {"patterns": [{"match": []}]}}}`: "repository.r.patterns[0].match",
		`{"scopeName": "source.a", "patterns": [{"captures": {"1": {"name": 2}}}]}`:     "patterns[0].captures.1.name",
		`{"scopeName": "source.a", "patterns": [{"captures": "1"}]}`:                    "patterns[0].captures",
	} {
		_, err := ParseGrammar([]byte(source))
		if err == nil || !strings.Contains(err.Error(), path) {
			t.Errorf("ParseGrammar(%s) = %v, want an error at %s", source, err, path)
		}
	}
}

// registryOf returns a registry holding raw.
func registryOf(raw *RawGrammar) *Registry {
	registry := NewRegistry()
	registry.Add(raw)
	return registry
}
