package regexp2

import (
	"slices"
	"testing"
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
		pattern string
		want    []string
	}{
		{`(?=\w?[\w\s-]*\b(?:class|(?<!@)interface|enum)\s+[\w$]+)`, []string{"class", "interface", "enum"}},
		{`^\s*([\w\s]*)(enum)\s+(\w+)`, []string{"enum"}},
		{`(^[ \t]+)?(?=//)`, []string{"//"}},
		{`a{3}b?`, []string{"aaa"}},
		{`(?:foo|bar)+baz`, []string{"baz"}},
		{`foo|\w+`, nil},
		{`(?!foo)\w+`, nil},
		{`(?<=foo)\w+`, nil},
		{`(?i)foo`, nil},
		{`(a)?\1`, nil},
		{`x*`, nil},
	}
	for _, c := range cases {
		re := MustCompile(c.pattern, 0)
		var got []string
		if re.code.Required != nil {
			got = re.code.Required.Literals()
		}
		if !slices.Equal(got, c.want) {
			t.Errorf("%q requires %q, want %q", c.pattern, got, c.want)
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
	}
	inputs := []string{
		"public class Foo extends Bar {",
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
