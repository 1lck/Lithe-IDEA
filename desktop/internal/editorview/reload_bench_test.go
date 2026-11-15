package editorview

import (
	"bytes"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/vivaui/viva/gfx"
)

// BenchmarkEditorViewReload is an external change reloaded into a clean view: the view takes the
// disk's text, which differs from the saved text by one line. The content is prepared on a worker
// as the window does, so the benchmark measures what the window thread does for the reload. The
// frame that follows is not measured here; the paint benchmarks cover it. The two contents
// alternate, each prepared against the text the view holds when it is applied, so every iteration
// reloads a changed document.
func BenchmarkEditorViewReload(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, canvas, editorperf.Go, size, true)
			original := editorperf.Text(editorperf.Go, size.Bytes)
			edited := bytes.Clone(original)
			at := bytes.IndexByte(original[len(original)/2:], '\n') + len(original)/2 + 1
			edited = append(edited[:at], append([]byte("// reloaded\n"), original[at:]...)...)
			// The view's saved text is the original rope. forward takes the view from it to the edited
			// text; backward takes the view from that back to the original, and its text is the
			// original rope itself, so the next forward is prepared against the text the view holds.
			forward := PrepareAgainst(v.SavedSnapshot(), edited)
			backward := PrepareAgainst(forward.text, original)
			backward.text = forward.base
			i := 0
			for ; b.Loop(); i++ {
				content := forward
				if i%2 == 1 {
					content = backward
				}
				if !v.Reload(content) {
					b.Fatal("a clean view refused the reload")
				}
			}
		})
	}
}
