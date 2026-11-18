package textmate

import (
	"fmt"
	"strings"
	"testing"
)

// TestMatchesVSCodeTextMate checks injections against vscode-textmate with sample.injection
// and the injection grammar of testdata/grammars; the tests here cover what it cannot.

func TestParseGrammarReadsInjectionsInJavaScriptOrder(t *testing.T) {
	raw := parseTestGrammar(t, `{"scopeName": "source.a", "injections": {
		"b": {"match": "1"}, "10": {"match": "2"}, "a": {"match": "3"}, "2": {"match": "4"},
		"b": {"match": "5"}, "4294967295": {"match": "6"}, "01": {"match": "7"}, "c": null
	}}`)
	var got []string
	for _, injection := range raw.Injections {
		got = append(got, injection.Selector+"="+injection.Rule.Match)
	}
	want := "2=4 10=2 b=5 a=3 4294967295=6 01=7"
	if strings.Join(got, " ") != want {
		t.Fatalf("injections %v, want %s", got, want)
	}
}

func TestParseGrammarRejectsWrongInjections(t *testing.T) {
	for source, path := range map[string]string{
		`{"scopeName": "source.a", "injections": []}`:                       "injections",
		`{"scopeName": "source.a", "injections": {"source": 1}}`:            "injections.source",
		`{"scopeName": "source.a", "injections": {"source": {"match": 1}}}`: "injections.source.match",
	} {
		_, err := ParseGrammar([]byte(source))
		if err == nil || !strings.Contains(err.Error(), path) {
			t.Errorf("ParseGrammar(%s) = %v, want an error at %s", source, err, path)
		}
	}
}

// scopeStack returns the stack of the space-separated scopes, outermost first.
func scopeStack(g *Grammar, scopes string) *ScopeStack {
	fields := strings.Fields(scopes)
	stack := &ScopeStack{scope: fields[0], depth: 1}
	return g.pushScopes(stack, strings.Join(fields[1:], " "))
}

func TestSelectorsMatchAsVSCodeTextMate(t *testing.T) {
	g := testGrammar(t, "source.injection")
	for _, c := range []struct {
		selector, scopes string
		want             []bool
	}{
		{"text.html", "text.html.basic", []bool{true}},
		{"text.htm", "text.html.basic", []bool{false}},
		{"text.html.basic.x", "text.html.basic", []bool{false}},
		// Names match in order, skipping scopes between them.
		{"source.php string", "text.html.php meta.embedded source.php string.quoted", []bool{true}},
		{"string source.php", "text.html.php meta.embedded source.php string.quoted", []bool{false}},
		{"source.php source.php", "text.html.php source.php", []bool{false}},
		{"source.php source.php", "source.php meta source.php", []bool{true}},
		{"text - string", "text.html string.quoted", []bool{false}},
		{"text - string", "text.html", []bool{true}},
		{"text -", "text.html", []bool{false}},
		{"- string", "text.html", []bool{true}},
		{"text - (string | comment)", "text.html comment.line", []bool{false}},
		{"text - (string, comment", "text.html comment.line", []bool{false}},
		{"(string, comment) text", "text.html", []bool{false}},
		{"a, b", "b", []bool{false, true}},
		{"", "a", nil},
		{"L:", "a", []bool{true}},
		// The names a wildcard leaves never match a scope.
		{"meta.tag.*.html", "meta.tag.any.html", []bool{false}},
	} {
		parts := parseSelector(c.selector)
		var got []bool
		for _, part := range parts {
			got = append(got, part.selector.matches(scopeStack(g, c.scopes)))
		}
		if fmt.Sprint(got) != fmt.Sprint(c.want) {
			t.Errorf("%q on %q = %v, want %v", c.selector, c.scopes, got, c.want)
		}
	}
}

func TestSelectorPriorities(t *testing.T) {
	var got []int
	for _, part := range parseSelector("L:a, R:b, c, X: d, L:") {
		got = append(got, part.priority)
	}
	if fmt.Sprint(got) != "[-1 1 0 0 -1]" {
		t.Fatalf("priorities %v", got)
	}
}

// tokenTexts tokenizes line with g and writes each token as its text and innermost scope.
func tokenTexts(t *testing.T, g *Grammar, line string) string {
	t.Helper()
	tokens, _, _ := g.NewTokenizer().TokenizeLine(nil, []byte(line), nil, 0)
	var out []string
	for i, token := range tokens {
		end := len(line)
		if i+1 < len(tokens) {
			end = tokens[i+1].Start
		}
		out = append(out, fmt.Sprintf("%q=%s", line[token.Start:end], token.Scopes.Scope()))
	}
	return strings.Join(out, " ")
}

func TestInjectedBeginEndRuleAddsOnlyItsPatterns(t *testing.T) {
	g, _ := registryOf(parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [], "injections": {
		"source.a": {"begin": "B", "end": "E", "name": "never.a", "patterns": [{"match": "P", "name": "p.a"}]}
	}}`)).Grammar("source.a")
	got := tokenTexts(t, g, "B P E")
	if want := `"B "=source.a "P"=p.a " E"=source.a`; got != want {
		t.Fatalf("tokens %s, want %s", got, want)
	}
}

func TestIncludedGrammarsInjectNothing(t *testing.T) {
	registry := NewRegistry()
	registry.Add(parseTestGrammar(t, `{"scopeName": "source.a", "patterns": [{"include": "source.b"}],
		"injections": {"source": {"patterns": [{"match": "A", "name": "a.a"}]}}}`))
	registry.Add(parseTestGrammar(t, `{"scopeName": "source.b", "patterns": [{"match": "x", "name": "x.b"}],
		"injections": {"source": {"patterns": [{"match": "B", "name": "b.b"}]}}}`))
	a, _ := registry.Grammar("source.a")
	if got, want := tokenTexts(t, a, "A B x"), `"A"=a.a " B "=source.a "x"=x.b`; got != want {
		t.Errorf("source.a: tokens %s, want %s", got, want)
	}
	b, _ := registry.Grammar("source.b")
	if got, want := tokenTexts(t, b, "A B x"), `"A "=source.b "B"=b.b " "=source.b "x"=x.b`; got != want {
		t.Errorf("source.b: tokens %s, want %s", got, want)
	}
}
