package syntax

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// BenchmarkEditorSyntaxSemanticBuild converts the semantic tokens a language server sends for a
// document into the highlighter's byte positions, the work SetSemantic does. The go variants
// send a few tokens on every tenth line of the document. The longline variant sends a fixed
// number of tokens spread over one line as long as the document, where each token's column is
// reached by walking the line from its start: a line read once per token would cost that many
// walks. The longline variant runs at the small size only, because the walk per token is the
// cost it measures.
func BenchmarkEditorSyntaxSemanticBuild(b *testing.B) {
	legend := NewSemanticLegend([]string{"variable"}, nil)
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			text := rope.New(editorperf.Text(editorperf.Go, size.Bytes))
			tokens := goSemanticTokens(text)
			b.ResetTimer()
			for b.Loop() {
				buildSemantic(text, legend, tokens)
			}
		})
	}
	b.Run("longline/100KiB", func(b *testing.B) {
		b.ReportAllocs()
		text := rope.New(editorperf.Text(editorperf.JSON, editorperf.Sizes()[0].Bytes))
		tokens := spreadSemanticTokens(text, 400)
		b.ResetTimer()
		for b.Loop() {
			buildSemantic(text, legend, tokens)
		}
	})
}

// goSemanticTokens are three tokens at the start of every tenth line of text.
func goSemanticTokens(text rope.Rope) []SemanticToken {
	var tokens []SemanticToken
	for line := 0; line < text.LineCount(); line += 10 {
		length := text.LineEnd(line) - text.LineStart(line)
		for _, at := range []int{0, 4, 8} {
			if at+3 <= length {
				tokens = append(tokens, SemanticToken{Line: uint32(line), StartChar: uint32(at), Length: 3})
			}
		}
	}
	return tokens
}

// spreadSemanticTokens are count tokens spaced evenly along the first line of text.
func spreadSemanticTokens(text rope.Rope, count int) []SemanticToken {
	length := text.LineEnd(0) - text.LineStart(0)
	tokens := make([]SemanticToken, 0, count)
	for i := 0; i < count; i++ {
		tokens = append(tokens, SemanticToken{Line: 0, StartChar: uint32(i * (length / count)), Length: 4})
	}
	return tokens
}
