package regexp2

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate/internal/regexp2/syntax"
)

// TestFindRunesSpansAgreesWithMatch checks the Lithe allocation-free search against the
// upstream Match it replaces, including groups that do not take part, repeated captures and
// balancing groups.
func TestFindRunesSpansAgreesWithMatch(t *testing.T) {
	cases := []struct{ pattern, input string }{
		{`(a)|(b)`, "xxb"},
		{`(\w)+`, "  abc"},
		{`(?<o>\()*(?<c-o>\))*`, "(()"},
		{`\b(if|else)\b(\s*)(\()?`, "x = else if("},
		{`(x)?y`, "zy"},
		{`nothing`, "abc"},
	}
	var dst []int
	for _, c := range cases {
		re := MustCompile(c.pattern, 0)
		runes := []rune(c.input)
		for start := 0; start <= len(runes); start++ {
			var want []int
			m, err := re.FindRunesMatchStartingAt(runes, start)
			if err != nil {
				t.Fatal(err)
			}
			if m != nil {
				for i := 0; i < m.GroupCount(); i++ {
					g := m.GroupByNumber(i)
					if len(g.Captures) == 0 {
						want = append(want, -1, -1)
					} else {
						want = append(want, g.Index, g.Index+g.Length)
					}
				}
			}
			var ok bool
			dst, ok, err = re.FindRunesSpans(dst, runes, start)
			if err != nil {
				t.Fatal(err)
			}
			if ok != (m != nil) || !slices.Equal(dst, want) {
				t.Errorf("%q in %q from %d: spans %v (match %v), want %v", c.pattern, c.input, start, dst, ok, want)
			}
		}
	}
}

// TestFindRunesSpansDoesNotAllocate checks the reason FindRunesSpans exists.
func TestFindRunesSpansDoesNotAllocate(t *testing.T) {
	re := MustCompile(`\b(public|private)\s+(\w+)`, 0)
	runes := []rune("  private final int count;")
	dst, _, _ := re.FindRunesSpans(nil, runes, 0)
	allocs := testing.AllocsPerRun(100, func() {
		dst, _, _ = re.FindRunesSpans(dst, runes, 0)
	})
	if allocs != 0 {
		t.Errorf("FindRunesSpans allocates %v times per search, want 0", allocs)
	}
}

// TestRequiredLiterals checks which literals the prefilter relies on.
func TestRequiredLiterals(t *testing.T) {
	cases := []struct {
		pattern  string
		want     []string
		anywhere bool
	}{
		{`(?=\w?[\w\s-]*\b(?:class|(?<!@)interface|enum)\s+[\w$]+)`, []string{"class", "interface", "enum"}, false},
		{`^\s*([\w\s]*)(enum)\s+(\w+)`, []string{"enum"}, false},
		{`(^[ \t]+)?(?=//)`, []string{"//"}, false},
		{`a{3}b?`, []string{"aaa"}, false},
		{`(?:foo|bar)+baz`, []string{"baz"}, false},
		{`foo|\w+`, nil, false},
		{`(?!foo)\w+`, nil, false},
		{`(?<=foo)\w+`, []string{"foo"}, true},
		{`(?<=ab)\w`, []string{"ab"}, true},
		{`(?<=\bconst\b)\s*(\w+)`, []string{"const"}, true},
		{`(?<=ab)c`, []string{"c"}, false},
		{`(?<!foo)\w+`, nil, false},
		{`(?i)foo`, nil, false},
		{`(a)?\1`, nil, false},
		{`x*`, nil, false},
	}
	for _, c := range cases {
		re := MustCompile(c.pattern, 0)
		var got []string
		anywhere := false
		if re.code.Required != nil {
			got = re.code.Required.Literals()
			anywhere = re.code.Required.Anywhere()
		}
		if !slices.Equal(got, c.want) || anywhere != c.anywhere {
			t.Errorf("%q requires %q (anywhere %v), want %q (anywhere %v)", c.pattern, got, anywhere, c.want, c.anywhere)
		}
	}
}

// TestRequiredDoesNotChangeMatches searches with and without the prefilter from every start
// position and expects the same answers.
func TestRequiredDoesNotChangeMatches(t *testing.T) {
	patterns := []string{
		`(?=\w?[\w\s-]*\b(?:class|(?<!@)interface|enum)\s+[\w$]+)`,
		`(?!new)(?=[\w<].*\s+)(?=([^=/]|/(?!/))+\()`,
		`(^[ \t]+)?(?=//)`,
		`\b(return|if|else)\b`,
		`(?:ab)+c|d`,
		`x(?=y)`,
		`(?<=ab)\w`,
		`(?<=\bconst\b)\s*(\w+)`,
		`(?<=a(?=b))b`,
	}
	inputs := []string{
		"public class Foo extends Bar {",
		"const (\n  a = 1\n)",
		"xab c",
		"  int count(int a) { return a; } // done",
		"abababc d",
		"xxy",
		"no literal here",
		"",
	}
	var with, without []int
	for _, pattern := range patterns {
		filtered := MustCompile(pattern, Multiline)
		plain := MustCompile(pattern, Multiline)
		if filtered.code.Required == nil {
			t.Fatalf("%q has no required literals", pattern)
		}
		code := *plain.code
		code.Required = nil
		plain.code = &code
		for _, input := range inputs {
			runes := []rune(input)
			for start := 0; start <= len(runes); start++ {
				var okWith, okWithout bool
				with, okWith, _ = filtered.FindRunesSpans(with, runes, start)
				without, okWithout, _ = plain.FindRunesSpans(without, runes, start)
				if okWith != okWithout || !slices.Equal(with, without) {
					t.Errorf("%q in %q from %d: %v %v with the filter, %v %v without", pattern, input, start, okWith, with, okWithout, without)
				}
			}
		}
	}
}

// TestStartAnalyses checks that the Lithe start analyses see through the shapes TextMate
// grammars use, so the search skips positions instead of trying each one.
func TestStartAnalyses(t *testing.T) {
	firstChars := []string{
		`(?=;|\)|\]|\.|,)`,
		`(?=\b(void|boolean))`,
		`(?=\w.*\s+\w+\s*\()`,
		`\s*(?=x)`,
	}
	for _, pattern := range firstChars {
		if re := MustCompile(pattern, Multiline); re.code.FcPrefix == nil {
			t.Errorf("%q has no first characters", pattern)
		}
	}
	anchors := []struct {
		pattern string
		want    syntax.AnchorLoc
	}{
		{`((?:^(?!\z))|(?!))[ ]{2,4}`, syntax.AnchorBol},
		{`(^a|^b)`, syntax.AnchorBol},
		{`(?:(?!)|^)\s+`, syntax.AnchorBol},
		{`(^a|b)`, 0},
		{`(\Aa|^b)`, 0},
		{`(^|\G)x`, 0},
	}
	for _, c := range anchors {
		re := MustCompile(c.pattern, Multiline)
		if got := re.code.Anchors & (syntax.AnchorBeginning | syntax.AnchorBol | syntax.AnchorStart | syntax.AnchorEndZ | syntax.AnchorEnd); got != c.want {
			t.Errorf("%q is anchored at %v, want %v", c.pattern, got, c.want)
		}
	}
}

// TestStartShortcutsDoNotChangeMatches searches with the start analyses and with none of them,
// which tries every position, from every start position and expects the same answers.
func TestStartShortcutsDoNotChangeMatches(t *testing.T) {
	patterns := []string{
		`(?=\w.*\s+\w+\s*\()`,
		`(?=;|\)|\]|\.|,)`,
		`(?=\b(void|boolean))`,
		`\s*(?=x)`,
		`(?=(?=a)\w)`,
		`(?=a)?b`,
		`(?=a)|b`,
		`(?=)`,
		`(?=[\w<].*\s+)(?!new)`,
		`(?!a)`,
		`(?!;)(?=\S)`,
		`\s*(?!x)`,
		`((?:^(?!\z))|(?!))[ ]{2,4}`,
		`(^a|^b)`,
		`(?:(?!)|^)\s+`,
		`(^a|b)`,
		`(\Aa|^b)`,
		`(^b|\Aa)`,
		`(^|\G)x`,
		`^\s*\w+`,
		`^$`,
		`^`,
		`(?<=\bconst\b)\s*(\w+)`,
		`(?<=ab)\w`,
		`(?<=foo)\w+`,
		`(?<=a(?=b))b`,
		`(?<!\w)x`,
	}
	inputs := []string{
		"abc",
		"xab c\n",
		"const (\n  a = 1\n)\n",
		"  public void run(int a) {\n",
		"boolean ok = x;\n",
		"foo bar; baz.qux, (x)\n",
		"  a\n    b\nab\n\n",
		"xx  \n  y",
		"a\nx\nb\n",
		"new Foo<T> bar",
		"",
		"\n",
	}
	var with, without []int
	for _, pattern := range patterns {
		fast := MustCompile(pattern, Multiline)
		plain := MustCompile(pattern, Multiline)
		code := *plain.code
		code.FcPrefix, code.BmPrefix, code.Anchors, code.Required = nil, nil, 0, nil
		plain.code = &code
		for _, input := range inputs {
			runes := []rune(input)
			for start := 0; start <= len(runes); start++ {
				var okWith, okWithout bool
				with, okWith, _ = fast.FindRunesSpans(with, runes, start)
				without, okWithout, _ = plain.FindRunesSpans(without, runes, start)
				if okWith != okWithout || !slices.Equal(with, without) {
					t.Errorf("%q in %q from %d: %v %v with the analyses, %v %v without", pattern, input, start, okWith, with, okWithout, without)
				}
			}
		}
	}
}
