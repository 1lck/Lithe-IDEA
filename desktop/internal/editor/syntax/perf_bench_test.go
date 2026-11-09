package syntax

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// This file is the syntax highlighter's part of the editor performance baseline: what coloring
// costs when a file is opened, scrolled to, repainted and typed in, measured on the shared
// fixtures of package editorperf. The benchmark names are compared by exact name across runs,
// so renaming one breaks its history. They use the highlighter without its background
// goroutine, driven by drain, so that every measured step is deterministic.

// viewportLines is how many lines one screen shows: an editor 800 points tall at about 13
// points per line.
const viewportLines = 60

// grammarKinds are the fixture kinds that have a grammar to color them.
var grammarKinds = []editorperf.Kind{editorperf.Go, editorperf.Java, editorperf.Markdown}

// sink receives what a benchmark computes so that the compiler cannot drop the work.
var sink int

// keystroke is the byte a simulated user types; a package variable keeps the benchmarks from
// allocating the slice they pass to Insert.
var keystroke = []byte{'x'}

// runKinds runs fn as the sub-benchmark <kind>/<size> for each kind with a grammar and each of
// sizes, with the syntax of the kind compiled and the document of that size built before the
// first iteration. The grammar is warmed first: tokenizing compiles its patterns the first time
// each is reached, which would otherwise land in the first iteration.
func runKinds(b *testing.B, sizes []editorperf.Size, fn func(b *testing.B, s *Syntax, text rope.Rope)) {
	for _, kind := range grammarKinds {
		for _, size := range sizes {
			b.Run(string(kind)+"/"+size.Name, func(b *testing.B) {
				s := testSyntax(b, kind.Language())
				warmGrammar(s, kind)
				text := rope.New(editorperf.Text(kind, size.Bytes))
				b.ReportAllocs()
				fn(b, s, text)
			})
		}
	}
}

// warmGrammar colors the first screen of a small document of kind with s on a throwaway
// highlighter, so the patterns that screen reaches are compiled before anything is timed.
func warmGrammar(s *Syntax, kind editorperf.Kind) {
	text := rope.New(editorperf.Text(kind, editorperf.SmallBytes))
	h := testHighlighter(s, text, 0, nil)
	paintViewport(h, nil, 0)
	h.Close()
}

// paintViewport does what a view does for one frame: it prepares the viewportLines lines from
// first and reads the tokens of each into dst, which it returns so the caller can keep its
// capacity.
func paintViewport(h *Highlighter, dst []Token, first int) []Token {
	h.Prepare(first, first+viewportLines-1)
	for line := first; line < first+viewportLines; line++ {
		dst = h.Line(dst[:0], line)
		sink += len(dst)
	}
	return dst
}

// typeAt is the i-th keystroke of a benchmark: an even one types a letter at offset at of text
// and an odd one deletes it again, each reported to h as the edit it is. It returns the new
// text.
func typeAt(h *Highlighter, text rope.Rope, at, i int) rope.Rope {
	if i%2 == 0 {
		next := text.Insert(at, keystroke)
		h.Edit(next, at, at, at+1)
		return next
	}
	next := text.Delete(at, at+1)
	h.Edit(next, at, at+1, at)
	return next
}

// BenchmarkEditorSyntaxViewportCold measures jumping into the middle of a file that no
// checkpoint has reached, as when a file is opened at a remembered position or its scroll bar
// is dragged: one iteration is a new highlighter preparing and reading the 60 lines of the
// viewport, the time until that screen is colored.
func BenchmarkEditorSyntaxViewportCold(b *testing.B) {
	runKinds(b, editorperf.Sizes(), func(b *testing.B, s *Syntax, text rope.Rope) {
		mid := text.LineCount() / 2
		dst := make([]Token, 0, 256)
		for b.Loop() {
			h := testHighlighter(s, text, 0, nil)
			dst = paintViewport(h, dst, mid)
			h.Close()
		}
	})
}

// BenchmarkEditorSyntaxViewportWarm measures repainting a screen whose tokens are cached: one
// iteration prepares and reads the 60 lines of the viewport again. A repaint happens on every
// cursor blink and scroll tick, so it must cost little and allocate nothing.
func BenchmarkEditorSyntaxViewportWarm(b *testing.B) {
	runKinds(b, editorperf.Sizes(), func(b *testing.B, s *Syntax, text rope.Rope) {
		mid := text.LineCount() / 2
		h := testHighlighter(s, text, 0, nil)
		b.Cleanup(h.Close)
		dst := paintViewport(h, make([]Token, 0, 256), mid)
		for b.Loop() {
			dst = paintViewport(h, dst, mid)
		}
	})
}

// BenchmarkEditorSyntaxTypeInLine measures typing in a colored screen: one iteration is one
// keystroke on a line in the middle of the viewport, alternately a letter typed and deleted,
// and the repaint of the 60 lines. It is the work the window thread does before the next frame,
// so it decides whether typing feels instant, and it must not depend on the document's size.
//
// The background pass has finished before the first keystroke, as it has by the time anyone
// types in a file they opened seconds ago; otherwise no checkpoint would reach the edited line
// and each keystroke would tokenize it from a guessed state, which is not what typing costs.
func BenchmarkEditorSyntaxTypeInLine(b *testing.B) {
	runKinds(b, editorperf.Sizes(), func(b *testing.B, s *Syntax, text rope.Rope) {
		mid := text.LineCount() / 2
		length := text.Len()
		at := text.LineEnd(mid + viewportLines/2)
		h := testHighlighter(s, text, 0, nil)
		b.Cleanup(h.Close)
		drain(b, h)
		dst := paintViewport(h, make([]Token, 0, 256), mid)
		i := 0
		for ; b.Loop(); i++ {
			text = typeAt(h, text, at, i)
			dst = paintViewport(h, dst, mid)
		}
		// The loop stops after an insert when it ran an odd number of times.
		if want := length + i%2; text.Len() != want {
			b.Fatalf("text holds %d bytes after %d edits, want %d", text.Len(), i, want)
		}
	})
}

// BenchmarkEditorSyntaxTypeCatchUp measures the background work an ordinary keystroke causes:
// one iteration is one keystroke on a line in the middle of the viewport, alternately a letter
// typed and deleted, followed by the bringing up to date of the checkpoints after it. The work
// must stop after the edited segment, where the tokenizer's state matches what it was, instead
// of tokenizing the rest of the file again, so it must not depend on the document's size.
//
// The background pass has finished before the first keystroke, as it has by the time anyone
// types in a file they opened seconds ago.
func BenchmarkEditorSyntaxTypeCatchUp(b *testing.B) {
	runKinds(b, editorperf.Sizes(), func(b *testing.B, s *Syntax, text rope.Rope) {
		mid := text.LineCount() / 2
		length := text.Len()
		at := text.LineEnd(mid + viewportLines/2)
		h := testHighlighter(s, text, 0, nil)
		b.Cleanup(h.Close)
		drain(b, h)
		paintViewport(h, nil, mid)
		i := 0
		for ; b.Loop(); i++ {
			text = typeAt(h, text, at, i)
			sink += drain(b, h)
		}
		// The loop stops after an insert when it ran an odd number of times.
		if want := length + i%2; text.Len() != want {
			b.Fatalf("text holds %d bytes after %d edits, want %d", text.Len(), i, want)
		}
	})
}

// BenchmarkEditorSyntaxFullPass measures the background pass that follows opening a file: one
// iteration tokenizes the whole small document once, from a new highlighter, until every
// checkpoint is known. Its throughput is what the pass costs per byte; a file 100 times as
// large takes 100 times as long to finish coloring.
func BenchmarkEditorSyntaxFullPass(b *testing.B) {
	runKinds(b, []editorperf.Size{editorperf.Small()}, func(b *testing.B, s *Syntax, text rope.Rope) {
		b.SetBytes(int64(text.Len()))
		for b.Loop() {
			h := testHighlighter(s, text, 0, nil)
			sink += drain(b, h)
			h.Close()
		}
	})
}

// BenchmarkEditorSyntaxFirstUse measures the first file of a language opened in a session: one
// iteration builds a syntax from a new registry, so its grammar is parsed and compiled again,
// then a highlighter of a small document that prepares and reads the first 60 lines. It is the
// time until that first screen is colored, grammar compilation included.
func BenchmarkEditorSyntaxFirstUse(b *testing.B) {
	for _, kind := range grammarKinds {
		b.Run(string(kind), func(b *testing.B) {
			language := kind.Language()
			text := rope.New(editorperf.Text(kind, editorperf.SmallBytes))
			dst := make([]Token, 0, 256)
			b.ReportAllocs()
			for b.Loop() {
				s := NewRegistry().Syntax(language)
				if s == nil {
					b.Fatalf("no syntax for %s", language)
				}
				h := testHighlighter(s, text, 0, nil)
				dst = paintViewport(h, dst, 0)
				h.Close()
			}
		})
	}
}
