package textmate

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

// grammarDirs hold the grammars the client bundles and those only the tests use.
var grammarDirs = []string{"../syntax/grammars", "testdata/grammars"}

// bundledRegistry returns a registry of every grammar in grammarDirs and their scope names.
func bundledRegistry(t testing.TB) (*Registry, []string) {
	t.Helper()
	registry := NewRegistry()
	var scopes []string
	for _, dir := range grammarDirs {
		files, err := filepath.Glob(filepath.Join(dir, "*.tmLanguage.json"))
		if err != nil || len(files) == 0 {
			t.Fatalf("no grammars in %s: %v", dir, err)
		}
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			raw, err := ParseGrammar(data)
			if err != nil {
				t.Fatalf("%s: %v", file, err)
			}
			registry.Add(raw)
			scopes = append(scopes, raw.ScopeName)
		}
	}
	return registry, scopes
}

// testGrammar returns the grammar of scope from bundledRegistry.
func testGrammar(t testing.TB, scope string) *Grammar {
	t.Helper()
	registry, _ := bundledRegistry(t)
	g, ok := registry.Grammar(scope)
	if !ok {
		t.Fatalf("no grammar %s", scope)
	}
	return g
}

func TestTranslate(t *testing.T) {
	cases := []struct{ in, out string }{
		{`\h+`, `[0-9a-fA-F]+`},
		{`[\h_]`, `[0-9a-fA-F_]`},
		{`a*+b`, `(?>a*)b`},
		{`(?:ab)++`, `(?>(?:ab)+)`},
		{`[a-z]?+`, `(?>[a-z]?)`},
		{`a{2,3}+`, `(?:a{2,3})+`},
		{`a{,3}`, `a{0,3}`},
		{`a{x}`, `a\{x}`},
		{`(?m).`, `(?s).`},
		{`(?i:abc)`, `(?i:abc)`},
		{`(?<name>x)\k<name>`, `(x)\1`},
		{`(a)(?<b>c)\k<b>`, `(a)(c)\2`},
		{`[[:alpha:]_]`, `[\p{L}\p{M}_]`},
		{`[a[bc]]`, `[abc]`},
		{`\x{41}\x41`, `AA`},
		{`\p{Alpha}`, `[\p{L}\p{M}]`},
		{`^a$`, `(?:^(?!\z))a$`},
		{`[^\]]`, `[^\]]`},
		{`\1\x31`, `\1\x31`},
		{`\/\-`, `\/\-`},
		{`[a-z&&[^aeiou]]`, `[a-z-[aeiou]]`},
		{`[^a[^b]]`, `[^a-[^b]]`},
		{`[\H]`, `[^0-9a-fA-F]`},
		{`\x{41 42}`, `(?:AB)`},
		{`[\x{41 42}-]`, `[AB\-]`},
		{`a{2,0}`, `(?>a{0,2})`},
		{`(?<b>x)?\g<b>`, `(x)?(?<1>x)`},
	}
	for _, c := range cases {
		got, err := translate(c.in, false, false)
		if err != nil {
			t.Errorf("translate(%q): %v", c.in, err)
			continue
		}
		if got != c.out {
			t.Errorf("translate(%q) = %q, want %q", c.in, got, c.out)
		}
		if _, err := compilePattern(c.in, false, false); err != nil && !strings.Contains(c.in, `\1`) {
			t.Errorf("compile(%q): %v", c.in, err)
		}
	}
	if got, _ := translate(`\Gx|\Ay`, true, true); got != `(?!)x|(?!)y` {
		t.Errorf("anchors not disallowed: %q", got)
	}
	for _, unsupported := range []string{`\K`, `\g<x>`, `\g<0>`, `(?~x)`, `(`, `)`} {
		if _, err := translate(unsupported, false, false); err == nil {
			t.Errorf("translate(%q) succeeded", unsupported)
		}
	}
}

// TestTranslatedMatches checks what translations without a one-to-one .NET form match.
func TestTranslatedMatches(t *testing.T) {
	cases := []struct {
		pattern, input, match string
		// group is the text group 1 captures, when the case says.
		group string
	}{
		// A recursive call matches nested brackets, the group and callDepth calls deep.
		{pattern: `(?<b>\[(?:[^\[\]]|\g<b>)*\])`, input: "x[a[b[c]]d]", match: "[a[b[c]]d]"},
		{pattern: `(?<b>\[(?:[^\[\]]|\g<b>)*\])`, input: "[[[[[[[[x]]]]]]]]", match: "[[[[[[[x]]]]]]]"},
		// A call captures into the group it calls.
		{pattern: `(?<c>[+-])?+([1-9])(?(<c>)|\g<c>)?+`, input: "1+", match: "1+", group: "+"},
		{pattern: `[\x{85}[^\p{Cc}]]+`, input: "\x01a\u0085b\x02", match: "a\u0085b"},
		{pattern: `[a-z&&[^aeiou]]+`, input: "aebcdi", match: "bcd"},
		{pattern: `[^a[^b]]+`, input: "abba", match: "bb"},
		{pattern: `[[^a]&&[^b]]+`, input: "abcdab", match: "cd"},
		{pattern: `[\x{41 43}]+`, input: "BCAB", match: "CA"},
		{pattern: `x[^"]{2,0}`, input: "xabc", match: "xab"},
		{pattern: `[[:^alpha:]]+`, input: "ab12c", match: "12"},
	}
	for _, c := range cases {
		re, err := compilePattern(c.pattern, false, false)
		if err != nil {
			t.Errorf("compile(%q): %v", c.pattern, err)
			continue
		}
		m, err := re.FindRunesMatchStartingAt([]rune(c.input), 0)
		if err != nil || m == nil {
			t.Errorf("%q did not match %q: %v", c.pattern, c.input, err)
			continue
		}
		if m.String() != c.match {
			t.Errorf("%q matched %q in %q, want %q", c.pattern, m.String(), c.input, c.match)
		}
		if c.group != "" && m.GroupByNumber(1).String() != c.group {
			t.Errorf("%q captured %q, want %q", c.pattern, m.GroupByNumber(1).String(), c.group)
		}
	}
}

func TestPossessiveDoesNotBacktrack(t *testing.T) {
	re, err := compilePattern(`a++a`, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := re.FindRunesMatchStartingAt([]rune("aaa"), 0); m != nil {
		t.Errorf("a++a matched %q", m.String())
	}
}

func TestCaretDoesNotMatchAfterTheFinalLineBreak(t *testing.T) {
	re, err := compilePattern(`^`, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := re.FindRunesMatchStartingAt([]rune("ab\n"), 1); m != nil {
		t.Errorf("^ matched at %d", m.Index)
	}
	if m, _ := re.FindRunesMatchStartingAt([]rune("ab\ncd"), 1); m == nil || m.Index != 3 {
		t.Errorf("^ did not match at the next line: %v", m)
	}
}

// TestBundledPatternsCompile compiles every pattern of the bundled grammars in every
// variant: a pattern that does not translate would silently never match.
func TestBundledPatternsCompile(t *testing.T) {
	registry, scopes := bundledRegistry(t)
	for _, scope := range scopes {
		g, ok := registry.Grammar(scope)
		if !ok {
			t.Fatalf("no grammar %s", scope)
		}
		for _, r := range compileAll(g) {
			if r.kind == externalRule {
				continue
			}
			for _, p := range []*pattern{r.match, r.begin, r.end, r.while} {
				if p == nil || p.hasBackReferences && (p == r.end || p == r.while) {
					continue
				}
				for variant := 0; variant < 4; variant++ {
					p.compiled(variant&1 == 0, variant&2 == 0)
				}
			}
		}
		if errs := g.PatternErrors(); len(errs) > 0 {
			t.Errorf("%s: %d patterns do not compile, first: %v", scope, len(errs), errs[0])
		}
	}
}

// compileAll compiles every grammar g includes and returns all its rules.
func compileAll(g *Grammar) []*rule {
	for id := 1; id < len(*g.rules.Load()); id++ {
		if r := g.rule(id); r.kind == externalRule {
			g.resolve(r)
		}
	}
	return (*g.rules.Load())[1:]
}

// goldenToken is one token as vscode-textmate produced it: start in UTF-16 code units and
// the scopes.
type goldenToken struct {
	start  int
	scopes string
}

func readGolden(t *testing.T, path string) [][]goldenToken {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var lines [][]goldenToken
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 1<<24)
	for scanner.Scan() {
		var raw [][2]json.RawMessage
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		tokens := make([]goldenToken, len(raw))
		for i, pair := range raw {
			if err := json.Unmarshal(pair[0], &tokens[i].start); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(pair[1], &tokens[i].scopes); err != nil {
				t.Fatal(err)
			}
		}
		lines = append(lines, tokens)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return lines
}

// utf16Offset converts a byte offset in line to UTF-16 code units, as JavaScript counts.
func utf16Offset(line string, offset int) int {
	units := 0
	for _, r := range line[:offset] {
		units += len(utf16.Encode([]rune{r}))
	}
	return units
}

func splitLines(data string) []string {
	data = strings.ReplaceAll(data, "\r\n", "\n")
	return strings.Split(strings.ReplaceAll(data, "\r", "\n"), "\n")
}

// TestMatchesVSCodeTextMate tokenizes the samples in testdata and compares every token with
// what vscode-textmate 9.3.2 and vscode-oniguruma 1.7.0, the engine of the earlier client,
// produced for the same grammars. scripts/desktop/generate-textmate-goldens.mjs regenerates the
// goldens after a grammar or sample changes.
func TestMatchesVSCodeTextMate(t *testing.T) {
	registry, _ := bundledRegistry(t)
	data, err := os.ReadFile("testdata/samples.json")
	if err != nil {
		t.Fatal(err)
	}
	// samples.json names each sample and the scope that tokenizes it.
	var samples map[string]string
	if err := json.Unmarshal(data, &samples); err != nil {
		t.Fatal(err)
	}
	for name, scope := range samples {
		t.Run(name, func(t *testing.T) {
			g, ok := registry.Grammar(scope)
			if !ok {
				t.Fatalf("no grammar %s", scope)
			}
			data, err := os.ReadFile(filepath.Join("testdata", name))
			if err != nil {
				t.Fatal(err)
			}
			golden := readGolden(t, filepath.Join("testdata", name+".tokens"))
			lines := splitLines(string(data))
			if len(lines) != len(golden) {
				t.Fatalf("%d lines, golden has %d", len(lines), len(golden))
			}
			tokenizer := g.NewTokenizer()
			var state *StateStack
			failures := 0
			for i, line := range lines {
				tokens, end, stopped := tokenizer.TokenizeLine(nil, []byte(line), state, 0)
				if stopped {
					t.Fatalf("line %d stopped without a limit", i+1)
				}
				state = end
				got := make([]string, len(tokens))
				for j, token := range tokens {
					got[j] = fmt.Sprintf("%d %s", utf16Offset(line, token.Start), token.Scopes)
				}
				want := make([]string, len(golden[i]))
				for j, token := range golden[i] {
					want[j] = fmt.Sprintf("%d %s", token.start, token.scopes)
				}
				if strings.Join(got, "\n") != strings.Join(want, "\n") {
					failures++
					if failures <= 3 {
						t.Errorf("line %d %q:\ngot:\n  %s\nwant:\n  %s", i+1, line,
							strings.Join(got, "\n  "), strings.Join(want, "\n  "))
					}
				}
			}
			if failures > 3 {
				t.Errorf("%d lines differ in all", failures)
			}
		})
	}
}

func TestTokenizeLineStopsAtItsLimit(t *testing.T) {
	g := testGrammar(t, "source.java")
	tokenizer := g.NewTokenizer()
	line := strings.Repeat("int a = 1; ", 5000)
	_, end, stopped := tokenizer.TokenizeLine(nil, []byte(line), nil, time.Nanosecond)
	if !stopped || end == nil {
		t.Fatalf("stopped = %v", stopped)
	}
}

func TestStatesConvergeAfterAClosedComment(t *testing.T) {
	g := testGrammar(t, "source.java")
	tokenizer := g.NewTokenizer()
	_, a, _ := tokenizer.TokenizeLine(nil, []byte("class A {"), nil, 0)
	_, inComment, _ := tokenizer.TokenizeLine(nil, []byte("  /* open"), a, 0)
	if inComment.Equal(a) {
		t.Fatal("an open comment does not change the state")
	}
	_, closed, _ := tokenizer.TokenizeLine(nil, []byte("  close */"), inComment, 0)
	if !closed.Equal(a) {
		t.Fatal("the state does not return after the comment closes")
	}
}

func TestTokensStartOnCharacterBoundaries(t *testing.T) {
	g := testGrammar(t, "source.java")
	line := `String 名字 = "中文 \u00e9 😀";`
	tokens, _, _ := g.NewTokenizer().TokenizeLine(nil, []byte(line), nil, 0)
	for _, token := range tokens {
		if !utf8.RuneStart(line[token.Start]) {
			t.Errorf("token starts inside a character at %d", token.Start)
		}
	}
}

func BenchmarkTokenizeJava(b *testing.B) {
	g := testGrammar(b, "source.java")
	data, err := os.ReadFile("testdata/Sample.java")
	if err != nil {
		b.Fatal(err)
	}
	lines := splitLines(string(data))
	tokenizer := g.NewTokenizer()
	var tokens []Token
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		var state *StateStack
		for _, line := range lines {
			tokens, state, _ = tokenizer.TokenizeLine(tokens[:0], []byte(line), state, 0)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*len(lines)), "ns/line")
}
