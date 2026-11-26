package syntax

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// BenchmarkEditorSyntaxCandidates measures an edit, incremental catch-up and the background
// snapshot consumed by pairing/indent guides even with both rainbow color switches off.
func BenchmarkEditorSyntaxCandidates(b *testing.B) {
	runKinds(b, []editorperf.Size{editorperf.Small(), {Name: "1MiB", Bytes: RainbowBracketMaxBytes}}, func(b *testing.B, kind editorperf.Kind, s *Syntax, text rope.Rope) {
		// The shared generator may finish its last line past the requested byte count.
		// This scenario exercises the feature's exact 1 MiB inclusive boundary.
		if text.Len() > RainbowBracketMaxBytes {
			text = text.Delete(RainbowBracketMaxBytes, text.Len())
		}
		h := newHighlighter(s, text, HighlighterOptions{LineLimit: -1, CollectCandidates: true}, false)
		b.Cleanup(h.Close)
		drain(b, h)
		// Editing the same early line at both sizes keeps the tokenization work comparable.
		at := text.LineEnd(viewportLines/2) - 1
		for b.Loop() {
			// A same-width numeric edit leaves candidate offsets and names unchanged.
			next := text.Delete(at, at+1).Insert(at, []byte("1"))
			h.Edit(next, at, at+1, at+1)
			drain(b, h)
			if _, err := h.Candidates(b.Context(), next); err != nil {
				b.Fatal(err)
			}
			h.Edit(text, at, at+1, at+1)
			drain(b, h)
			result, err := h.Candidates(b.Context(), text)
			if err != nil {
				b.Fatal(err)
			}
			sink += len(result.Brackets) + len(result.Variables)
		}
	})
}
