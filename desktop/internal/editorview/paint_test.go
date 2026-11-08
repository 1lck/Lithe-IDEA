package editorview

import (
	"math"
	"strings"
	"testing"

	"github.com/vivaui/viva/ui"
)

// lineChunks is the labels a paint drew for the text of lines: the ones with runs, as the
// line numbers have none.
func lineChunks(canvas *ui.Canvas) []ui.Text {
	var chunks []ui.Text
	for _, text := range canvas.Texts() {
		if text.RunCount > 0 {
			chunks = append(chunks, text)
		}
	}
	return chunks
}

// The single line of a minified JSON file must not become one label: the renderer refuses a
// texture wider than 16384 pixels, and that stopped the app when such a file was opened.
func TestLongLineIsDrawnInBoundedChunksOfTheVisibleColumns(t *testing.T) {
	line := `{"items":[` + strings.Repeat(`{"id":1,"name":"x"},`, 5000) + `{}]}`
	v := newTestView(t, line)
	area := ui.Rect{X: 0, Y: 0, Width: 900, Height: 400}
	canvas := new(ui.Canvas)

	for _, scrollX := range []float32{0, 123_456.5, 1e9} {
		canvas.Reset()
		v.scrollX = scrollX
		v.Paint(canvas, area, Look{})
		chunks := lineChunks(canvas)
		if len(chunks) == 0 {
			t.Fatalf("scrollX %v: the line drew no label", scrollX)
		}
		// The view shows the text from the gutter's edge, textPad before textLeft, to its right
		// edge; the line covers that span except where it starts or ends inside it.
		lineLeft := v.textLeft - v.scrollX
		lineRight := lineLeft + float32(len(line))*v.cellW
		left := max(v.textLeft-textPad, lineLeft)
		right := min(area.X+area.Width, lineRight)
		first, last := chunks[0], chunks[len(chunks)-1]
		if first.Bounds.X > left || last.Bounds.X+last.Bounds.Width < right {
			t.Fatalf("scrollX %v: chunks span %v to %v, want %v to %v covered",
				v.scrollX, first.Bounds.X, last.Bounds.X+last.Bounds.Width, left, right)
		}
		for _, chunk := range chunks {
			if chunk.Bounds.Width > chunkWidth+1 {
				t.Fatalf("scrollX %v: a label is %v points wide, more than %v", v.scrollX, chunk.Bounds.Width, chunkWidth+1)
			}
			// The line is ASCII, so a chunk's text is the line's bytes from its first column.
			column := int(math.Round(float64((chunk.Bounds.X - v.textLeft + v.scrollX) / v.cellW)))
			if column%v.chunkCells() != 0 {
				t.Fatalf("scrollX %v: a chunk starts at column %d, off the grid of %d", v.scrollX, column, v.chunkCells())
			}
			if want := line[column : column+len(chunk.Value)]; chunk.Value != want {
				t.Fatalf("scrollX %v: the chunk at column %d is %.20q…, want %.20q…", v.scrollX, column, chunk.Value, want)
			}
		}
	}
}

// A wide character keeps its columns when the line is cut into chunks: it belongs to the
// chunk it starts in, and the runs of the next chunk count columns from that chunk's start.
func TestChunkRunsCountColumnsFromTheChunk(t *testing.T) {
	canvas := new(ui.Canvas)
	cellW, _ := canvas.MonoCellSize(fontSize, 0)
	chunk := max(int(chunkWidth/cellW), 1)
	// The wide character takes the last column of the first chunk and the first of the next.
	v := newTestView(t, strings.Repeat("a", chunk-1)+"中bc")
	v.Paint(canvas, ui.Rect{Width: 2 * chunkWidth, Height: 200}, Look{})
	chunks := lineChunks(canvas)
	if len(chunks) != 2 {
		t.Fatalf("drew %d chunks, want two", len(chunks))
	}
	if !strings.HasSuffix(chunks[0].Value, "中") || chunks[1].Value != "bc" {
		t.Fatalf("chunks hold %.8q… and %q, want the wide character ending the first and bc the second", chunks[0].Value[len(chunks[0].Value)-8:], chunks[1].Value)
	}
	runs := canvas.TextRuns(chunks[1])
	if len(runs) != 1 || runs[0].Column != 1 || runs[0].Cells != 2 {
		t.Fatalf("second chunk runs = %+v, want bc at column 1 of the chunk, after the wide character's second half", runs)
	}
}
