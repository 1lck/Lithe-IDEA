package syntax

import (
	"errors"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

func TestDecodeSemanticTokens(t *testing.T) {
	got, err := DecodeSemanticTokens(nil, []uint32{0, 5, 3, 0, 0, 0, 4, 2, 1, 0, 2, 1, 1, 0, 1})
	if err != nil {
		t.Fatal(err)
	}
	want := []SemanticToken{
		{Line: 0, StartChar: 5, Length: 3},
		{Line: 0, StartChar: 9, Length: 2, Type: 1},
		{Line: 2, StartChar: 1, Length: 1, Modifiers: 1},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("decoded %v, want %v", got, want)
	}
	if _, err := DecodeSemanticTokens(nil, []uint32{0, 1, 2}); !errors.Is(err, ErrSemanticData) {
		t.Fatalf("short data: error %v", err)
	}
}

func TestSemanticLegend(t *testing.T) {
	legend := NewSemanticLegend(
		[]string{"class", "field", "type_parameter", "Unknown", "builtinType"},
		[]string{"static", "async", "declaration"})
	for _, c := range []struct {
		typ, mods uint32
		want      string
	}{
		{0, 0, "class"},
		{0, 1 | 4, "class.declaration.static"},
		{1, 1, "property.static"},
		{2, 4, "typeParameter.declaration"},
		{2, 2, "typeParameter"},
		{4, 0, "type"},
	} {
		name, ok := legend.Name(c.typ, c.mods)
		if !ok || name.String() != c.want {
			t.Fatalf("Name(%d, %b) = %q, %v, want %q", c.typ, c.mods, name, ok, c.want)
		}
	}
	for _, typ := range []uint32{3, 5, 1 << 31} {
		if _, ok := legend.Name(typ, 0); ok {
			t.Fatalf("type %d is styled", typ)
		}
	}
}

func TestAdvanceUTF16(t *testing.T) {
	line := "中文😀abc"
	for _, c := range []struct {
		from, col, target uint32
		want              int
		wantCol           uint32
		ok                bool
	}{
		{0, 0, 0, 0, 0, true},
		{0, 0, 2, 6, 2, true},
		{0, 0, 4, 10, 4, true},
		// Inside the surrogate pair: the end of the character.
		{0, 0, 3, 10, 4, true},
		{10, 4, 7, 13, 7, true},
		{10, 4, 9, 13, 7, false},
	} {
		got, col, ok := advanceUTF16(line, int(c.from), c.col, c.target)
		if got != c.want || col != c.wantCol || ok != c.ok {
			t.Fatalf("advanceUTF16(%d, col %d, target %d) = %d, %d, %v, want %d, %d, %v", c.from, c.col, c.target, got, col, ok, c.want, c.wantCol, c.ok)
		}
	}
}

func TestBuildSemantic(t *testing.T) {
	text := rope.FromString("中文 name\nabc\n")
	legend := NewSemanticLegend([]string{"variable", "unstyled"}, nil)
	variable := uint32(Intern("variable"))
	got := buildSemantic(text, legend, []SemanticToken{
		{Line: 1, StartChar: 1, Length: 9},          // runs past its line: ends there
		{Line: 0, StartChar: 3, Length: 4},          // "name", after two one-unit characters and a space
		{Line: 0, StartChar: 4, Length: 1},          // overlaps the token before it
		{Line: 0, StartChar: 0, Length: 0},          // empty
		{Line: 0, StartChar: 0, Length: 1, Type: 1}, // not styled
		{Line: 1, StartChar: 3, Length: 1},          // starts at the end of its line
		{Line: 7, StartChar: 0, Length: 1},          // past the text
	})
	want := semanticTokens{0, 7, 11, variable, 1, 1, 3, variable}
	if !slices.Equal(got, want) {
		t.Fatalf("built %v, want %v", got, want)
	}
}

func TestSemanticEdit(t *testing.T) {
	// The line is "foo bar", foo and bar are tokens, and line 2 has a token too.
	base := func() semanticTokens { return semanticTokens{0, 0, 3, 1, 0, 4, 7, 2, 2, 0, 2, 3} }
	for _, c := range []struct {
		name                                 string
		startLine, startCol, endLine, endCol int
		newlines, lastLen                    int
		firstByte                            byte
		want                                 semanticTokens
	}{
		{"word typed after a token grows it", 0, 3, 0, 3, 0, 1, 'x',
			semanticTokens{0, 0, 4, 1, 0, 5, 8, 2, 2, 0, 2, 3}},
		{"other text typed after a token does not", 0, 3, 0, 3, 0, 1, '.',
			semanticTokens{0, 0, 3, 1, 0, 5, 8, 2, 2, 0, 2, 3}},
		{"typing inside a token grows it", 0, 1, 0, 1, 0, 2, '-',
			semanticTokens{0, 0, 5, 1, 0, 6, 9, 2, 2, 0, 2, 3}},
		{"typing before a token moves it", 0, 0, 0, 0, 0, 1, 'x',
			semanticTokens{0, 1, 4, 1, 0, 5, 8, 2, 2, 0, 2, 3}},
		{"a line break inside a token cuts it", 0, 1, 0, 1, 1, 0, '\n',
			semanticTokens{0, 0, 1, 1, 1, 3, 6, 2, 3, 0, 2, 3}},
		{"deleting across tokens joins what is left", 0, 1, 0, 5, 0, 0, 0,
			semanticTokens{0, 0, 1, 1, 0, 1, 3, 2, 2, 0, 2, 3}},
		{"a token deleted whole goes", 0, 0, 0, 3, 0, 0, 0,
			semanticTokens{0, 1, 4, 2, 2, 0, 2, 3}},
		{"deleting line breaks moves later lines up", 0, 7, 2, 0, 0, 0, 0,
			semanticTokens{0, 0, 3, 1, 0, 4, 7, 2, 0, 7, 9, 3}},
		{"pasting lines moves later ones down", 1, 0, 1, 0, 2, 4, 'a',
			semanticTokens{0, 0, 3, 1, 0, 4, 7, 2, 4, 0, 2, 3}},
	} {
		got := base().edit(c.startLine, c.startCol, c.endLine, c.endCol, c.newlines, c.lastLen, c.firstByte)
		if !slices.Equal(got, c.want) {
			t.Fatalf("%s: tokens %v, want %v", c.name, got, c.want)
		}
	}
}

// TestBuildSemanticAcrossLeaves checks the one-pass build against a line-by-line reading of a text
// spread over many leaves, with characters outside the BMP and tokens on lines of every kind.
func TestBuildSemanticAcrossLeaves(t *testing.T) {
	text := rope.New(editorperf.Text(editorperf.Mixed, 300<<10))
	legend := NewSemanticLegend([]string{"variable"}, nil)
	var tokens []SemanticToken
	for line := 0; line < text.LineCount(); line += 3 {
		for _, at := range []uint32{0, 1, 5, 9} {
			tokens = append(tokens, SemanticToken{Line: uint32(line), StartChar: at, Length: 1 + at%4})
		}
	}
	got := buildSemantic(text, legend, tokens)

	var want semanticTokens
	lastLine, lastEnd := -1, 0
	for _, tok := range tokens {
		line := text.Line(int(tok.Line))
		start, startCol, ok := advanceUTF16(line, 0, 0, tok.StartChar)
		if !ok || start >= len(line) {
			continue
		}
		end, _, _ := advanceUTF16(line, start, startCol, startCol+tok.Length)
		if int(tok.Line) == lastLine && start < lastEnd {
			continue
		}
		want = append(want, tok.Line, uint32(start), uint32(end), uint32(Intern("variable")))
		lastLine, lastEnd = int(tok.Line), end
	}
	if len(got) != len(want) {
		t.Fatalf("built %d values, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("value %d = %d, want %d", i, got[i], want[i])
		}
	}
}
