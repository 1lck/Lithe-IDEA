package syntax

import (
	"context"
	"hash/fnv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

func wantHash(s string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return h.Sum64()
}

func TestBundledDocCommentDialectsAllowlistAndThemeInheritance(t *testing.T) {
	r := NewRegistry()
	want := map[string]DocCommentDialects{
		"java":            {Block: "javadoc-html"},
		"kotlin":          {Block: "javadoc-html"},
		"javascript":      {Block: "javadoc-html"},
		"javascriptreact": {Block: "javadoc-html"},
		"typescript":      {Block: "javadoc-html"},
		"typescriptreact": {Block: "javadoc-html"},
		"rust":            {Block: "markdown-html", Line: "markdown-html"},
		"c":               {Block: "javadoc-html"},
		"cpp":             {Block: "javadoc-html"},
		"php":             {Block: "javadoc-html"},
	}

	for _, lang := range bundledLanguages {
		expected := want[lang.ID]
		if lang.DocComments != expected {
			t.Errorf("%s: DocComments = %+v, want %+v", lang.ID, lang.DocComments, expected)
		}
		if s := r.Syntax(lang.ID); s != nil {
			if got := s.DocComments(); got != expected {
				t.Errorf("Syntax(%q).DocComments() = %+v, want %+v", lang.ID, got, expected)
			}
		}
	}

	// Verify comment.documentation.line inherits comment styling across schemes.
	palette := DefaultPalette()
	for _, scheme := range []string{SchemeLithe, SchemeIDEA, SchemeVSCode, SchemeGitHub, SchemeOne} {
		for _, dark := range []bool{false, true} {
			theme := BuildTheme(ThemeOptions{Dark: dark, Scheme: scheme, ItalicComments: true}, palette)
			docStyle := theme.Match("comment.documentation")
			lineStyle := theme.Match("comment.documentation.line")
			if lineStyle != docStyle {
				t.Errorf("scheme=%s dark=%v: comment.documentation.line style %+v != comment.documentation %+v", scheme, dark, lineStyle, docStyle)
			}
		}
	}

	// Verify Rust /// lines classify as comment.documentation.line.
	rustSyn := r.Syntax("rust")
	got := tokenNames(t, rustSyn, "/// Doc line\nfn main() {}\n", map[string]string{
		"///":      "comment.documentation.line",
		"Doc line": "comment.documentation.line",
	})
	for text, tok := range got {
		if tok != "comment.documentation.line" {
			t.Errorf("rust %q token = %q, want comment.documentation.line", text, tok)
		}
	}
}

func TestExtractDocCommentsJavaAndTextBlock(t *testing.T) {
	r := NewRegistry()
	syn := r.Syntax("java")
	src := strings.Join([]string{
		"package demo;",
		"/**",
		" * Real class Javadoc.",
		" * @param <T> element",
		" */",
		"class Demo {",
		`    String block = """`,
		"        /** fake inside text block */",
		`        """;`,
		"    /** inline */ int x = 1;",
		"    /**/",
		"    /** single line */",
		"    void m() {}",
		"}",
	}, "\n")
	text := rope.FromString(src)

	got, truncated := ExtractDocComments(context.Background(), syn, text, 1<<20)
	if truncated {
		t.Fatal("unexpected truncation")
	}
	if len(got) != 2 {
		t.Fatalf("got %d doc comments, want 2: %+v", len(got), got)
	}
	if got[0].StartLine != 1 || got[0].EndLine != 4 || got[0].ShellKind != DocShellBlockStar || got[0].Dialect != "javadoc-html" {
		t.Fatalf("first range = %+v", got[0])
	}
	slice0, _ := text.Substring(got[0].StartByte, got[0].EndByte)
	if !strings.HasPrefix(slice0, "/**\n") || !strings.HasSuffix(slice0, " */") {
		t.Fatalf("first slice = %q", slice0)
	}
	if got[0].ContentHash != wantHash(slice0) {
		t.Fatalf("first hash = %x, want %x", got[0].ContentHash, wantHash(slice0))
	}

	if got[1].StartLine != 11 || got[1].EndLine != 11 {
		t.Fatalf("second range = %+v, want line 11", got[1])
	}
	slice1, _ := text.Substring(got[1].StartByte, got[1].EndByte)
	if slice1 != "/** single line */" || got[1].ContentHash != wantHash(slice1) {
		t.Fatalf("second slice = %q hash = %x", slice1, got[1].ContentHash)
	}
}

func TestExtractDocCommentsJSRegexTemplateAndTSJSDoc(t *testing.T) {
	r := NewRegistry()
	jsSrc := strings.Join([]string{
		"const r = /[/*]/;",
		"const s = `",
		"/** fake in template */",
		"`;",
		"/** Real JSDoc */",
		"export function f() {}",
	}, "\n")
	for _, lang := range []string{"javascript", "javascriptreact", "typescript", "typescriptreact"} {
		t.Run(lang, func(t *testing.T) {
			syn := r.Syntax(lang)
			text := rope.FromString(jsSrc)
			got, truncated := ExtractDocComments(context.Background(), syn, text, 1<<20)
			if truncated {
				t.Fatal("unexpected truncation")
			}
			if len(got) != 1 || got[0].StartLine != 4 || got[0].EndLine != 4 || got[0].Dialect != "javadoc-html" {
				t.Fatalf("%s: got %+v, want single JSDoc on line 4", lang, got)
			}
			s, _ := text.Substring(got[0].StartByte, got[0].EndByte)
			if s != "/** Real JSDoc */" {
				t.Fatalf("%s: slice = %q", lang, s)
			}
		})
	}
}

func TestExtractDocCommentsRustNestedRawStringLineAndInnerDocs(t *testing.T) {
	r := NewRegistry()
	syn := r.Syntax("rust")
	src := strings.Join([]string{
		"//! Crate doc line 1",
		"//! Crate doc line 2",
		"/// Item doc line 1",
		"///",
		"/// Item doc line 2",
		"fn a() {",
		`    let fake = r#"`,
		"/** fake in raw string */",
		"/// fake line doc",
		"//! fake inner doc",
		`"#;`,
		"    /* outer normal",
		"     * /* nested normal */",
		"     * /** fake doc inside normal comment */",
		"     */",
		"}",
		"/**",
		" * Outer block doc",
		" * /* nested block comment */",
		" * Still outer block doc",
		" */",
		"/*! Inner block doc */",
		"//// Four slashes is not a doc comment",
		"/**/",
		"fn b() {}",
	}, "\n")
	text := rope.FromString(src)
	got, truncated := ExtractDocComments(context.Background(), syn, text, 1<<20)
	if truncated {
		t.Fatal("unexpected truncation")
	}
	if len(got) != 4 {
		for i, g := range got {
			s, _ := text.Substring(g.StartByte, g.EndByte)
			t.Logf("[%d] lines=%d..%d shell=%s slice=%q", i, g.StartLine, g.EndLine, g.ShellKind, s)
		}
		t.Fatalf("got %d ranges, want 4", len(got))
	}
	// 0: //! lines 0..1
	if got[0].StartLine != 0 || got[0].EndLine != 1 || got[0].ShellKind != DocShellLineSlash || got[0].Dialect != "markdown-html" {
		t.Fatalf("range 0 = %+v", got[0])
	}
	// 1: /// lines 2..4 (did not merge with //!)
	if got[1].StartLine != 2 || got[1].EndLine != 4 || got[1].ShellKind != DocShellLineSlash || got[1].Dialect != "markdown-html" {
		t.Fatalf("range 1 = %+v", got[1])
	}
	// 2: /** ... /* ... */ ... */ lines 16..20
	if got[2].StartLine != 16 || got[2].EndLine != 20 || got[2].ShellKind != DocShellBlockStar || got[2].Dialect != "markdown-html" {
		t.Fatalf("range 2 = %+v", got[2])
	}
	// 3: /*! Inner block doc */ line 21
	if got[3].StartLine != 21 || got[3].EndLine != 21 || got[3].ShellKind != DocShellBlockStar || got[3].Dialect != "markdown-html" {
		t.Fatalf("range 3 = %+v", got[3])
	}
}

func TestExtractDocCommentsCCppKotlinPHP(t *testing.T) {
	r := NewRegistry()
	cases := []struct {
		lang string
		src  string
		want int
	}{
		{
			lang: "c",
			src:  "/**\n * C doc\n */\n/*! Doxygen bang */\nint main(void) { return 0; }\n",
			want: 2,
		},
		{
			lang: "cpp",
			src:  "/**\n * C++ doc\n */\n/*! C++ bang */\nint main() { return 0; }\n",
			want: 2,
		},
		{
			lang: "kotlin",
			src:  "/**\n * KDoc\n */\nfun main() {}\n",
			want: 1,
		},
		{
			lang: "php",
			src:  "<?php\n/**\n * PHPDoc\n */\nfunction f() {}\n",
			want: 1,
		},
	}
	for _, tc := range cases {
		t.Run(tc.lang, func(t *testing.T) {
			syn := r.Syntax(tc.lang)
			got, truncated := ExtractDocComments(context.Background(), syn, rope.FromString(tc.src), 1<<20)
			if truncated || len(got) != tc.want {
				t.Fatalf("%s: got %d (truncated=%v), want %d: %+v", tc.lang, len(got), truncated, tc.want, got)
			}
			for _, g := range got {
				if g.ShellKind != DocShellBlockStar || g.Dialect != "javadoc-html" {
					t.Errorf("%s: unexpected shell/dialect: %+v", tc.lang, g)
				}
			}
		})
	}
}

func TestExtractDocCommentsAdjacentBlocksNeverMergeAndInlineSkipped(t *testing.T) {
	r := NewRegistry()
	syn := r.Syntax("java")
	src := strings.Join([]string{
		"/** a */",
		"/** b */",
		"/** c *//** d */",
		"/** e */ /** f */",
		"/** inline */ int x = 1;",
		"int y = 2; /** trailing */",
		"/**/",
		"/***/",
		"/**   */",
	}, "\n")
	text := rope.FromString(src)
	got, truncated := ExtractDocComments(context.Background(), syn, text, 1<<20)
	if truncated {
		t.Fatal("unexpected truncation")
	}
	if len(got) != 2 {
		t.Fatalf("got %d ranges, want 2: %+v", len(got), got)
	}
	s0, _ := text.Substring(got[0].StartByte, got[0].EndByte)
	s1, _ := text.Substring(got[1].StartByte, got[1].EndByte)
	if s0 != "/** a */" || got[0].StartLine != 0 || got[0].EndLine != 0 {
		t.Fatalf("first = %+v %q", got[0], s0)
	}
	if s1 != "/** b */" || got[1].StartLine != 1 || got[1].EndLine != 1 {
		t.Fatalf("second = %+v %q", got[1], s1)
	}
}

func TestExtractDocCommentsLimitsAndUnsupportedLanguages(t *testing.T) {
	r := NewRegistry()
	javaSyn := r.Syntax("java")
	goSyn := r.Syntax("go")

	// Unsupported language / nil syntax returns nil, false.
	if got, trunc := ExtractDocComments(context.Background(), nil, rope.FromString("/** x */"), 1024); got != nil || trunc {
		t.Fatalf("nil syntax: got=%v trunc=%v", got, trunc)
	}
	if got, trunc := ExtractDocComments(context.Background(), goSyn, rope.FromString("/** x */"), 1024); got != nil || trunc {
		t.Fatalf("go syntax: got=%v trunc=%v", got, trunc)
	}

	// maxBytes truncation returns nil, true before reading rope bytes.
	if got, trunc := ExtractDocComments(context.Background(), javaSyn, rope.FromString("/** hello world */"), 8); got != nil || !trunc {
		t.Fatalf("maxBytes exceeded: got=%v trunc=%v, want nil, true", got, trunc)
	}

	// Cap at 1024 blocks sets truncated = true.
	var many strings.Builder
	for range maxDocCommentBlocks + 10 {
		many.WriteString("/** block */\n")
	}
	got, trunc := ExtractDocComments(context.Background(), javaSyn, rope.FromString(many.String()), 1<<20)
	if !trunc || len(got) != maxDocCommentBlocks {
		t.Fatalf("block cap: len=%d trunc=%v, want %d, true", len(got), trunc, maxDocCommentBlocks)
	}

	// Cancelled context stops cleanly.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got, trunc := ExtractDocComments(ctx, javaSyn, rope.FromString("/** x */"), 1024); got != nil || !trunc {
		t.Fatalf("cancelled ctx: got=%v trunc=%v, want nil, true", got, trunc)
	}

	// An over-limit line leaves TextMate lexical state unknown (e.g. an open JS
	// template literal). Stop scanning instead of misclassifying subsequent text.
	jsSyn := r.Syntax("javascript")
	longTemplateOpen := "const s = `" + strings.Repeat("a", maxLineBytes+64) + "\n/** Not a doc comment */\n`;\n"
	got, trunc = ExtractDocComments(context.Background(), jsSyn, rope.FromString(longTemplateOpen), 1<<20)
	if !trunc || len(got) != 0 {
		t.Fatalf("over-limit template literal: got=%+v trunc=%v, want empty, true", got, trunc)
	}
}
