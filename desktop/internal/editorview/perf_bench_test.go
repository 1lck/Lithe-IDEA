package editorview

// The benchmarks in this file measure what the window thread does for the editor: the frame it
// paints and the work a keystroke, a scroll or an open adds to it. Every document comes from the
// editorperf fixtures, so a run is comparable with the one before it. Each iteration that edits the
// text undoes itself on the next, so a benchmark stays on the same document however long it runs.
//
// A benchmark name is <Benchmark>/<variant or kind>/<size>, and perfhistory compares runs by that
// exact name: rename nothing here without renaming its history.

import (
	"runtime"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/editorperf"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// benchRegistry is the language registry the benchmarks color with. It is shared, as the app's is,
// so the grammars compile once and not once per view.
var benchRegistry = sync.OnceValue(syntax.NewRegistry)

var (
	// benchArea is the editor's size in the frame: a window of a laptop's size.
	benchArea = gfx.Rect{Width: 1200, Height: 800}
	// benchLook is the look the frames are painted in. Its colors stay zero, as the paint tests'
	// do, because the colors do not change the work.
	benchLook = Look{Dark: true}
)

// benchSyntax is the syntax that colors kind, nil for a kind with no language.
func benchSyntax(kind editorperf.Kind) *syntax.Syntax {
	id := kind.Language()
	if id == "" {
		return nil
	}
	return benchRegistry().Syntax(id)
}

// benchConfig is the configuration the window gives a view of text: the same hits as the real
// window declares, so a frame lays out the minimap and both scrollbars. It stops the benchmark when
// a kind that has a language finds no syntax for it, which would otherwise time plain text under
// the name of a colored document.
func benchConfig(b *testing.B, kind editorperf.Kind, text []byte, highlight bool) Config {
	b.Helper()
	cfg := Config{
		HitID:           gfx.Item(1),
		Label:           "bench",
		Content:         Prepare(text),
		MinimapID:       gfx.Item(2),
		MinimapToggleID: gfx.Item(3),
		VerticalBarID:   gfx.Item(4),
		HorizontalBarID: gfx.Item(5),
	}
	if highlight {
		cfg.Syntax = benchSyntax(kind)
		if cfg.Syntax == nil && kind.Language() != "" {
			b.Fatalf("no syntax for the language %q of the %s document", kind.Language(), kind)
		}
	}
	return cfg
}

// frame paints v into a canvas that starts empty, as the window does for every frame it draws.
func frame(v *View, canvas *gfx.Canvas) {
	canvas.Reset()
	v.Paint(canvas, benchArea, benchLook)
}

// benchView is a view of the kind's document of the size, laid out and scrolled so that its middle
// line is in the middle of the window, with the colors of that viewport ready. Each layout func
// runs after the first frame and before the second, for a change that the layout of the second
// frame has to take in, such as soft wrapping.
func benchView(b *testing.B, kind editorperf.Kind, size editorperf.Size, highlight bool, layout ...func(v *View)) *View {
	b.Helper()
	v := New(benchConfig(b, kind, editorperf.Text(kind, size.Bytes), highlight))
	b.Cleanup(v.Close)
	// Close stops only the background checkpoint pass. The view still tokenizes what it paints and
	// what it edits on the window thread, and that is what these benchmarks measure. The background
	// pass is measured by the syntax package's FullPass and TypeCatchUp benchmarks, and running it
	// beside these measurements would make them depend on scheduling.
	v.hl.Close()
	canvas := new(gfx.Canvas)
	frame(v, canvas)
	v.GoToLine(v.text.LineCount()/2 + 1)
	for _, apply := range layout {
		if apply != nil {
			apply(v)
		}
	}
	frame(v, canvas)
	// Revealing the caret puts its line at the bottom edge of the window. Half a window up puts it
	// in the middle, so that the lines the benchmarks mark, select and scroll over are in view.
	v.scroll = max(v.scroll-benchArea.Height/2, 0)
	frame(v, canvas)
	return v
}

// placeCaret puts the caret, with nothing selected, at offset.
func placeCaret(v *View, offset int) {
	v.anchor, v.caret = offset, offset
}

// requireLength stops the benchmark unless the document is want bytes long. The mutating
// benchmarks undo each edit on the next iteration, so after the loop the text is at its original
// length, or one edit ahead of it when the loop ended between the two halves of a pair.
func requireLength(b *testing.B, v *View, want int) {
	b.Helper()
	if got := v.text.Len(); got != want {
		b.Fatalf("the document is %d bytes after the loop, want %d: an iteration did not undo what the one before it did", got, want)
	}
}

// paintCase is one variant of BenchmarkEditorViewPaint.
type paintCase struct {
	name      string
	kind      editorperf.Kind
	highlight bool
	// layout changes the view before the frame that lays it out, and arrange after it is laid out
	// and scrolled to the middle of the document.
	layout, arrange func(v *View)
}

var paintCases = []paintCase{
	{name: "plain", kind: editorperf.Go},
	{name: "go", kind: editorperf.Go, highlight: true},
	{name: "java", kind: editorperf.Java, highlight: true},
	{name: "wrap", kind: editorperf.Go, highlight: true, layout: func(v *View) { v.SetWrap(true) }},
	{name: "minimap", kind: editorperf.Go, highlight: true, layout: func(v *View) { v.SetMinimap(true) }},
	{name: "longline", kind: editorperf.JSON, highlight: true, arrange: func(v *View) {
		// The visible columns are in the middle of the line, where neither end of it helps.
		v.scrollX = v.maxScrollX() / 2
	}},
	{name: "cjk", kind: editorperf.Markdown, highlight: true},
	{name: "mixed", kind: editorperf.Mixed},
	{name: "selection", kind: editorperf.Go, highlight: true, arrange: func(v *View) {
		mid := v.text.LineOf(v.caret)
		first, last := max(mid-20, 0), min(mid+20, v.text.LineCount()-1)
		v.anchor, v.caret = v.text.LineStart(first), v.text.LineEnd(last)
	}},
	{name: "markers", kind: editorperf.Go, highlight: true, arrange: func(v *View) {
		// A marker on every line of the viewport, as a file full of warnings has. A line with
		// no text gets none: SetMarkers drops a marker that covers no cell.
		mid := v.text.LineOf(v.caret)
		var markers []Marker
		for line := max(mid-30, 0); line <= min(mid+30, v.text.LineCount()-1); line++ {
			length := v.lineEnd(line) - v.text.LineStart(line)
			markers = append(markers, Marker{Line: line, Start: 0, End: min(8, length), Severity: MarkerWarning})
		}
		v.SetMarkers(markers)
	}},
}

// BenchmarkEditorViewPaint is one frame of a view that nothing has changed since its last, as the
// window paints it for the caret to blink. It is the floor of every other benchmark here: the work
// of a frame that shows the same text, at a size of file, in a language and in a mode of the view.
func BenchmarkEditorViewPaint(b *testing.B) {
	for _, c := range paintCases {
		for _, size := range editorperf.Sizes() {
			b.Run(c.name+"/"+size.Name, func(b *testing.B) {
				b.ReportAllocs()
				canvas := new(gfx.Canvas)
				v := benchView(b, c.kind, size, c.highlight, c.layout)
				if c.arrange != nil {
					c.arrange(v)
					frame(v, canvas)
				}
				for b.Loop() {
					frame(v, canvas)
				}
			})
		}
	}
}

// BenchmarkEditorViewType is a keystroke and the frame that shows it: a character typed at the end
// of the middle line, and then deleted. It is the latency between a key and the text on screen, and
// what an edit costs a document the size of the file: the rope, the highlighter, the widest-line
// scan and the comparison with the saved text.
func BenchmarkEditorViewType(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			original := v.text.Len()
			placeCaret(v, v.lineEnd(v.text.LineOf(v.caret)))
			typed := app.TextEvent{Kind: app.TextInsert, Text: "x"}
			i := 0
			for ; b.Loop(); i++ {
				if i%2 == 0 {
					v.applyText(typed)
				} else {
					v.press(gfx.KeyBackspace, 0)
				}
				frame(v, canvas)
			}
			requireLength(b, v, original+i%2)
		})
	}
}

// BenchmarkEditorViewEnter is the Enter key and the frame that shows it, on an empty line, and then
// Backspace to take the line break back. Unlike a typed character it adds a line, so the line index
// of the rope, the highlighter's line states and the wrap layout all shift for every line below.
func BenchmarkEditorViewEnter(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			original := v.text.Len()
			mid := v.text.LineOf(v.caret)
			empty := -1
			for line, last := mid, min(mid+10000, v.text.LineCount()); line < last; line++ {
				if v.lineEnd(line) == v.text.LineStart(line) {
					empty = line
					break
				}
			}
			if empty < 0 {
				b.Fatal("the Go document has no empty line within 10000 lines after its middle")
			}
			placeCaret(v, v.text.LineStart(empty))
			i := 0
			for ; b.Loop(); i++ {
				if i%2 == 0 {
					v.press(gfx.KeyEnter, 0)
				} else {
					v.press(gfx.KeyBackspace, 0)
				}
				frame(v, canvas)
			}
			// An Enter on an empty line has no indentation to repeat, so it adds the line break alone.
			requireLength(b, v, original+i%2)
		})
	}
}

// BenchmarkEditorViewUndoRedo is Undo and Redo of one typed character, each with the frame that
// shows it. Undo puts a whole text back, so the highlighter drops everything it knows and the view
// scans the widest line again over the whole document: the cost a user waits for on the undo chord.
func BenchmarkEditorViewUndoRedo(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			original := v.text.Len()
			placeCaret(v, v.lineEnd(v.text.LineOf(v.caret)))
			v.applyText(app.TextEvent{Kind: app.TextInsert, Text: "x"})
			i := 0
			for ; b.Loop(); i++ {
				var ok bool
				if i%2 == 0 {
					ok = v.Undo()
				} else {
					ok = v.Redo()
				}
				if !ok {
					b.Fatalf("iteration %d had no step to undo or redo", i)
				}
				frame(v, canvas)
			}
			// The typed character is in the text before the first iteration, and each Undo takes it
			// out and each Redo puts it back.
			requireLength(b, v, original+1-i%2)
		})
	}
}

// BenchmarkEditorViewCaretMove is the Down key and then the Up key, each with the frame that shows
// it: holding an arrow key, which is a frame per repeat, in a document of the size.
func BenchmarkEditorViewCaretMove(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			for i := 0; b.Loop(); i++ {
				if i%2 == 0 {
					v.press(gfx.KeyDown, 0)
				} else {
					v.press(gfx.KeyUp, 0)
				}
				frame(v, canvas)
			}
		})
	}
}

// BenchmarkEditorViewPageMove is Page Down and then Page Up, each with the frame that shows it. A
// page is a jump to lines the view has not painted, so its frame colors a viewport of lines that
// were not in view before, unlike a frame of a caret that moved one line.
func BenchmarkEditorViewPageMove(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			for i := 0; b.Loop(); i++ {
				if i%2 == 0 {
					v.press(gfx.KeyPageDown, 0)
				} else {
					v.press(gfx.KeyPageUp, 0)
				}
				frame(v, canvas)
			}
		})
	}
}

// BenchmarkEditorViewScroll is a trackpad scroll step of three lines down and then three lines up,
// each with the frame that shows it: dragging two fingers over the text, which is a frame per
// report of the trackpad.
func BenchmarkEditorViewScroll(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			step := 3 * v.lineH
			for i := 0; b.Loop(); i++ {
				delta := step
				if i%2 != 0 {
					delta = -step
				}
				result, ok := v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: delta, Precise: true})
				if !ok || !result.Repaint {
					b.Fatalf("iteration %d did not scroll the view: handled %v, repaint %v", i, ok, result.Repaint)
				}
				frame(v, canvas)
			}
		})
	}
}

// BenchmarkEditorViewPaste is a paste of 1 MiB of text at the end of the middle line, the frame that
// shows it, the undo that takes it back and the frame that shows that. The paste is the largest edit
// a user makes in one step, and the undo after it is the one the user waits for.
func BenchmarkEditorViewPaste(b *testing.B) {
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true)
			original := v.text.Len()
			at := v.lineEnd(v.text.LineOf(v.caret))
			paste := app.TextEvent{Kind: app.TextPaste, Text: string(editorperf.Text(editorperf.Go, 1<<20))}
			for b.Loop() {
				placeCaret(v, at)
				v.applyText(paste)
				frame(v, canvas)
				if !v.Undo() {
					b.Fatal("the paste left no step to undo")
				}
				frame(v, canvas)
			}
			requireLength(b, v, original)
		})
	}
}

// BenchmarkEditorViewOpen is what the window thread does to show a file a worker has read and
// prepared: it builds the view of the prepared content and paints the first frame, which colors
// the first screen. It is the pause between the file being ready and the user seeing it. The
// worker's half is BenchmarkEditorViewPrepareReload.
func BenchmarkEditorViewOpen(b *testing.B) {
	for _, kind := range editorperf.Kinds() {
		for _, size := range editorperf.Sizes() {
			b.Run(string(kind)+"/"+size.Name, func(b *testing.B) {
				b.ReportAllocs()
				canvas := new(gfx.Canvas)
				text := editorperf.Text(kind, size.Bytes)
				cfg := benchConfig(b, kind, text, true)
				for b.Loop() {
					// The background pass runs beside the window thread and is measured by the syntax
					// benchmarks; stopping it at once keeps it from competing with the next iteration.
					v := New(cfg)
					v.hl.Close()
					frame(v, canvas)
					v.Close()
				}
			})
		}
	}
}

// BenchmarkEditorViewPrepareReload is the half of opening or reloading a file that runs on a worker:
// Prepare, which builds the rope from the bytes read and scans for the widest line. Both are linear
// in the file, and they keep the window from freezing as long as they stay off the window thread.
// The name is older than opening a file prepared on a worker too, and is kept so that the history
// stays comparable.
func BenchmarkEditorViewPrepareReload(b *testing.B) {
	for _, kind := range editorperf.Kinds() {
		for _, size := range editorperf.Sizes() {
			b.Run(string(kind)+"/"+size.Name, func(b *testing.B) {
				b.ReportAllocs()
				text := editorperf.Text(kind, size.Bytes)
				b.SetBytes(int64(len(text)))
				for b.Loop() {
					Prepare(text)
				}
			})
		}
	}
}

// BenchmarkEditorViewRewrap is a wrapped editor painted at 1200 points wide and then at 900, as it is
// while the user drags the window's edge: every resize changes the columns the text wraps at, so the
// view breaks every line into rows again.
func BenchmarkEditorViewRewrap(b *testing.B) {
	wide, narrow := gfx.Rect{Width: 1200, Height: 800}, gfx.Rect{Width: 900, Height: 800}
	for _, size := range editorperf.Sizes() {
		b.Run("go/"+size.Name, func(b *testing.B) {
			b.ReportAllocs()
			canvas := new(gfx.Canvas)
			v := benchView(b, editorperf.Go, size, true, func(v *View) { v.SetWrap(true) })
			// The view is laid out at the wide size now. A frame at the narrow one, before the loop,
			// makes the first iteration a resize too, as every other one is.
			canvas.Reset()
			v.Paint(canvas, narrow, benchLook)
			for i := 0; b.Loop(); i++ {
				area := wide
				if i%2 != 0 {
					area = narrow
				}
				canvas.Reset()
				v.Paint(canvas, area, benchLook)
			}
		})
	}
}

// BenchmarkEditorViewMemory is what one open document keeps alive besides the bytes the worker read:
// the rope, the line index, the highlighter's caches and the first frame's buffers, in bytes, as
// "retained-B" and per byte of the text as "retained/text-byte". The timing of this benchmark is not
// meaningful, as it forces collections to count.
func BenchmarkEditorViewMemory(b *testing.B) {
	kinds := []editorperf.Kind{editorperf.Go, editorperf.JSON, editorperf.Markdown, editorperf.Mixed}
	for _, kind := range kinds {
		for _, size := range editorperf.Sizes() {
			b.Run(string(kind)+"/"+size.Name, func(b *testing.B) {
				b.ReportAllocs()
				canvas := new(gfx.Canvas)
				text := editorperf.Text(kind, size.Bytes)
				cfg := benchConfig(b, kind, text, true)
				// One view that is not counted pays for what opening a file does only once per process:
				// compiling the grammar, building the theme and sizing the canvas's buffers. Without it
				// the first document would be charged for them.
				warm := New(cfg)
				warm.hl.Close()
				frame(warm, canvas)
				warm.Close()
				// The rope is part of what a document keeps, so each view is opened from content
				// prepared inside the measured span, and the warm view's content is let go.
				cfg.Content = Content{}
				var retained uint64
				for b.Loop() {
					before := editorperf.LiveHeap()
					open := cfg
					open.Content = Prepare(text)
					v := New(open)
					// The background pass would add checkpoints while the heap is read, so how far it
					// got would decide the result; its memory is the syntax package's to measure.
					v.hl.Close()
					frame(v, canvas)
					after := editorperf.LiveHeap()
					runtime.KeepAlive(v)
					v.Close()
					retained = 0
					if after > before {
						retained = after - before
					}
				}
				b.ReportMetric(float64(retained), "retained-B")
				b.ReportMetric(float64(retained)/float64(len(text)), "retained/text-byte")
			})
		}
	}
}
