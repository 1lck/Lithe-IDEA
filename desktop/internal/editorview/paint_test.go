package editorview

import (
	"math"
	"strings"
	"testing"

	"github.com/vivaui/viva/ui"
)

// lineLabels is the labels a paint of v drew for the text of lines: the ones clipped to the
// text, right of the gutter.
func lineLabels(canvas *ui.Canvas, v *View) []ui.Text {
	var labels []ui.Text
	for _, text := range canvas.Texts() {
		if text.RunCount > 0 && text.HasClip && text.ClipOf.X >= v.textLeft-textPad-0.01 {
			labels = append(labels, text)
		}
	}
	return labels
}

// numberLabels is the line numbers a paint of v drew: the labels clipped to the gutter.
func numberLabels(canvas *ui.Canvas, v *View) []ui.Text {
	var labels []ui.Text
	for _, text := range canvas.Texts() {
		if text.HasClip && text.ClipOf.X+text.ClipOf.Width <= v.textLeft-textPad+0.01 {
			labels = append(labels, text)
		}
	}
	return labels
}

// The single line of a minified JSON file is drawn as one label of the columns the view shows.
// A label of the whole line stopped the app, as the renderer refuses a texture wider than 16384
// pixels, and a label starting left of the window is moved to x 0 by Viva's painter, which drew
// it over the text after it when the line was scrolled sideways.
func TestLongLineIsOneLabelOfTheVisibleColumnsInsideTheWindow(t *testing.T) {
	line := `{"items":[` + strings.Repeat(`{"id":1,"name":"x"},`, 5000) + `{}]}`
	v := newTestView(t, line)
	canvas := new(ui.Canvas)

	for _, left := range []float32{0, 240} {
		area := ui.Rect{X: left, Y: 30, Width: 900, Height: 400}
		for _, scrollX := range []float32{0, 3.3, 61.7, 1037.25, 123_456.5, 1e9} {
			canvas.Reset()
			v.scrollX = scrollX
			v.Paint(canvas, area, Look{})
			labels := lineLabels(canvas, v)
			if len(labels) != 1 {
				t.Fatalf("area at %v, scrollX %v: the line drew %d labels, want one", left, v.scrollX, len(labels))
			}
			label := labels[0]
			if label.Bounds.X < area.X || label.Bounds.X < 0 {
				t.Fatalf("area at %v, scrollX %v: the label starts at %v, left of the view", left, v.scrollX, label.Bounds.X)
			}
			if label.Bounds.Width > area.Width+2*v.cellW+1 {
				t.Fatalf("area at %v, scrollX %v: the label is %v points wide, more than the view", left, v.scrollX, label.Bounds.Width)
			}
			// The view shows the text from the gutter's edge, textPad before textLeft, to its
			// right edge; the line covers that span except where it starts or ends inside it.
			lineLeft := v.textLeft - v.scrollX
			lineRight := lineLeft + float32(len(line))*v.cellW
			from := max(v.textLeft-textPad, lineLeft)
			to := min(area.X+area.Width, lineRight)
			if label.Bounds.X > from || label.Bounds.X+label.Bounds.Width < to {
				t.Fatalf("area at %v, scrollX %v: the label spans %v to %v, want %v to %v covered",
					left, v.scrollX, label.Bounds.X, label.Bounds.X+label.Bounds.Width, from, to)
			}
			// The line is ASCII, so the label's text is the line's bytes from its first column.
			column := int(math.Round(float64((label.Bounds.X - v.textLeft + v.scrollX) / v.cellW)))
			if want := line[column : column+len(label.Value)]; label.Value != want {
				t.Fatalf("area at %v, scrollX %v: the label at column %d is %.20q…, want %.20q…", left, v.scrollX, column, label.Value, want)
			}
		}
	}
}

// A view wider than labelWidth draws a line as labels side by side, and a wide character that
// would cross the end of one starts the next, whose runs count columns from its own start.
func TestWideViewSplitsALineIntoAdjacentLabels(t *testing.T) {
	canvas := new(ui.Canvas)
	cellW, _ := canvas.MonoCellSize(fontSize, 0)
	limit := max(int(labelWidth/cellW), 1)
	v := newTestView(t, strings.Repeat("a", limit-1)+"中bc")
	v.Paint(canvas, ui.Rect{Width: 2 * labelWidth, Height: 200}, Look{})
	labels := lineLabels(canvas, v)
	if len(labels) != 2 {
		t.Fatalf("drew %d labels, want two", len(labels))
	}
	if labels[0].Value != strings.Repeat("a", limit-1) || labels[1].Value != "中bc" {
		t.Fatalf("labels hold %d bytes and %q, want the a's and then the wide character with bc", len(labels[0].Value), labels[1].Value)
	}
	if got, want := labels[1].Bounds.X, labels[0].Bounds.X+float32(limit-1)*v.cellW; math.Abs(float64(got-want)) > 0.01 {
		t.Fatalf("second label starts at %v, want %v, where the first one's text ends", got, want)
	}
	runs := canvas.TextRuns(labels[1])
	if len(runs) != 2 || runs[0].Column != 0 || runs[0].Cells != 2 || runs[1].Column != 2 || runs[1].Cells != 2 {
		t.Fatalf("second label runs = %+v, want the wide character at column 0 and bc at column 2", runs)
	}
}

// A character the left edge of the view cuts keeps its column: a tab shows only its spaces from
// the first visible column, and a wide character starts the label a cell early, still inside
// the window.
func TestCharacterCutByTheLeftEdgeKeepsItsColumn(t *testing.T) {
	canvas := new(ui.Canvas)
	area := ui.Rect{Width: 900, Height: 200}
	tail := strings.Repeat("x", 400)

	tab := newTestView(t, "\tabc"+tail)
	tab.Paint(canvas, area, Look{})
	tab.scrollX = textPad + 2.5*tab.cellW
	canvas.Reset()
	tab.Paint(canvas, area, Look{})
	labels := lineLabels(canvas, tab)
	if len(labels) != 1 || !strings.HasPrefix(labels[0].Value, "  abc") {
		t.Fatalf("labels = %d, first %.8q…, want one starting with the tab's last two spaces", len(labels), labels[0].Value)
	}
	if got, want := labels[0].Bounds.X, tab.textLeft+2*tab.cellW-tab.scrollX; math.Abs(float64(got-want)) > 0.01 {
		t.Fatalf("label starts at %v, want %v, at column 2", got, want)
	}

	wide := newTestView(t, "中abc"+tail)
	wide.Paint(canvas, area, Look{})
	wide.scrollX = textPad + 1.5*wide.cellW
	canvas.Reset()
	wide.Paint(canvas, area, Look{})
	labels = lineLabels(canvas, wide)
	if len(labels) != 1 || !strings.HasPrefix(labels[0].Value, "中abc") {
		t.Fatalf("labels = %d, first %.8q…, want one starting with the wide character", len(labels), labels[0].Value)
	}
	if labels[0].Bounds.X < 0 {
		t.Fatalf("label starts at %v, left of the window", labels[0].Bounds.X)
	}
	if got, want := labels[0].Bounds.X, wide.textLeft-wide.scrollX; math.Abs(float64(got-want)) > 0.01 {
		t.Fatalf("label starts at %v, want %v, at column 0", got, want)
	}
}
