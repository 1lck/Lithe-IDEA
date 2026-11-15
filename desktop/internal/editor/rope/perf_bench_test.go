package rope

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
)

// This file is the rope's part of the editor performance baseline: the costs a user meets
// before and while an open document is shown, measured on the shared fixtures of package
// editorperf at its small and large sizes. The benchmark names are compared by exact name
// across runs, so renaming one breaks its history.

// viewportLines is how many lines one screen shows: an editor 800 points tall at about 13
// points per line.
const viewportLines = 60

// sink receives what a benchmark computes so that the compiler cannot drop the work.
var sink int

// keystroke is the byte a simulated user types; a package variable keeps the benchmarks from
// allocating the slice they pass to Insert.
var keystroke = []byte{'x'}

// lcg is a linear congruential generator, enough to scatter indices without the cost or the
// nondeterminism of a shared source of randomness.
type lcg uint64

// next returns the next number. The low bits of a congruential generator repeat quickly, so
// callers use the high ones.
func (x *lcg) next() uint64 {
	*x = *x*6364136223846793005 + 1442695040888963407
	return uint64(*x)
}

// randomIndices returns 1024 pseudo-random indices in [0, n), the same ones on every run, for a
// benchmark to cycle through with idx[i&1023].
func randomIndices(n int) []int {
	x := lcg(1)
	idx := make([]int, 1024)
	for i := range idx {
		idx[i] = int(x.next()>>33) % n
	}
	return idx
}

// forEachGoSize runs fn as the sub-benchmark go/<size> for each size of the baseline, with the
// Go document of that size built before the first iteration.
func forEachGoSize(b *testing.B, fn func(b *testing.B, text []byte)) {
	for _, size := range editorperf.Sizes() {
		b.Run(string(editorperf.Go)+"/"+size.Name, func(b *testing.B) {
			text := editorperf.Text(editorperf.Go, size.Bytes)
			b.ReportAllocs()
			fn(b, text)
		})
	}
}

// BenchmarkEditorRopeBuild measures what opening a file costs before anything is painted: one
// iteration builds the rope of the whole document from its bytes.
func BenchmarkEditorRopeBuild(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		b.SetBytes(int64(len(text)))
		for b.Loop() {
			sink += New(text).Len()
		}
	})
}

// BenchmarkEditorRopeTypePair measures typing in the middle of a document: one iteration is
// one keystroke, alternately a letter inserted and the same letter deleted. The cost of a
// keystroke must not grow with the size of the document.
func BenchmarkEditorRopeTypePair(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		r := New(text)
		length := r.Len()
		at := r.LineEnd(r.LineCount() / 2)
		i := 0
		for ; b.Loop(); i++ {
			if i%2 == 0 {
				r = r.Insert(at, keystroke)
			} else {
				r = r.Delete(at, at+1)
			}
		}
		// The loop stops after an insert when it ran an odd number of times.
		if want := length + i%2; r.Len() != want {
			b.Fatalf("rope holds %d bytes after %d edits, want %d", r.Len(), i, want)
		}
		sink += r.Len()
	})
}

// BenchmarkEditorRopeLineStart measures finding where a line begins, which every paint, scroll
// and cursor move does: one iteration is one lookup of a random line.
func BenchmarkEditorRopeLineStart(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		r := New(text)
		idx := randomIndices(r.LineCount())
		for i := 0; b.Loop(); i++ {
			sink += r.LineStart(idx[i&1023])
		}
	})
}

// BenchmarkEditorRopeLineOf measures finding which line a byte offset is on, as a click, an
// edit and a diagnostic do: one iteration is one lookup of a random offset.
func BenchmarkEditorRopeLineOf(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		r := New(text)
		idx := randomIndices(r.Len() + 1)
		for i := 0; b.Loop(); i++ {
			sink += r.LineOf(idx[i&1023])
		}
	})
}

// BenchmarkEditorRopeViewportLines measures what painting a screen reads from the text: one
// iteration appends the 60 lines of the viewport, from the middle of the document, into one
// reused buffer. Painting must not allocate, so neither may this.
func BenchmarkEditorRopeViewportLines(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		r := New(text)
		first := r.LineCount() / 2
		buf := make([]byte, 0, 4096)
		for b.Loop() {
			for line := first; line < first+viewportLines; line++ {
				buf = r.AppendLine(buf[:0], line)
				sink += len(buf)
			}
		}
	})
}

// BenchmarkEditorRopeBytes measures flattening the whole document into one slice: one
// iteration is one call to Bytes. It is the price of any code path that copies all of the text,
// kept here to show what such a path costs when it runs on every keystroke.
func BenchmarkEditorRopeBytes(b *testing.B) {
	forEachGoSize(b, func(b *testing.B, text []byte) {
		r := New(text)
		b.SetBytes(int64(r.Len()))
		for b.Loop() {
			sink += len(r.Bytes())
		}
	})
}
