package syntax

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

func TestRainbowBracketsUseGrammarScopesAndUTF8Offsets(t *testing.T) {
	registry := NewRegistry()
	for _, tc := range []struct{ language, annotated string }{
		{"go", "package main\r\nfunc main«(«) «{\r\n    // { [ (\r\n    _ = `raw { [ ( 👋`\r\n    _ = «[«]int«{1, «(2 + 3«)«}\r\n«}\r\n"},
		{"java", "class Example «{\n    /* comment [\n       ( remains a comment */\n    char close = '}';\n    String marker = \"👋 [\"; int inCode = «(1 + 2«);\n«}\n"},
		{"javascript", "const matcher = /[/*]/;\nconst text = `literal [()] ${mark«(«{key: '}'«}«)} tail []`;\nconst value = «(work«(«[1«]«)«);"},
		{"typescript", "const view = `outer ${`nested { literal }`} tail`;\nconst run = «(n: number«) => «[«(n + 1«)«];"},
		{"rust", "fn main«(«) «{\n    let raw = r#\"👋 { [\"#;\n    let close = ')';\n    /* comment {\n       [ still a comment */\n    let pair = «(«[1, 2«], 3«);\n«}\n"},
	} {
		t.Run(tc.language, func(t *testing.T) {
			language := registry.Syntax(tc.language)
			if language == nil {
				t.Fatal("expected a bundled grammar")
			}
			// In the fixture, mark only the source brackets that should be sent to Core.
			var source strings.Builder
			var want []Bracket
			for annotated := tc.annotated; annotated != ""; {
				before, after, found := strings.Cut(annotated, "«")
				source.WriteString(before)
				if !found {
					break
				}
				want = append(want, Bracket{Offset: uint32(source.Len()), Bracket: after[:1]})
				annotated = after
			}
			got := RainbowBrackets(t.Context(), rope.FromString(source.String()), language)
			if !slices.Equal(got, want) {
				t.Fatalf("got brackets %v, want %v", got, want)
			}
		})
	}
}

func TestRainbowBracketsKeepBoundedPrefix(t *testing.T) {
	language := NewRegistry().Syntax("go")
	for _, tc := range []struct{ name, source string }{
		{"oversized document", strings.Repeat(" ", RainbowBracketMaxBytes) + "()"},
		{"oversized line", "func main() {}\n" + strings.Repeat(" ", maxLineBytes+1) + "\n()"},
		{"too many candidates", "package main\n" + strings.Repeat("var _ = (1)\n", rainbowBracketMaxCount/2+1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := RainbowBrackets(t.Context(), rope.FromString(tc.source), language)
			want := 0
			switch tc.name {
			case "oversized line":
				want = 4
			case "too many candidates":
				want = rainbowBracketMaxCount
			}
			if len(got) != want {
				t.Fatalf("bounded prefix returned %d brackets, want %d", len(got), want)
			}
		})
	}
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if got := RainbowBrackets(cancelled, rope.FromString("package main\nfunc main() {}"), language); len(got) != 0 {
		t.Fatalf("cancelled snapshot returned %d brackets", len(got))
	}
}
