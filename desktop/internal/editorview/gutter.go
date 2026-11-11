package editorview

import (
	"math"
	"sort"

	"github.com/vivaui/viva/gfx"
)

// Gutter decorations and line annotations: what a host (the Git integration, for one) draws
// beside the text without owning the paint. The view paints only the lines in view, finds
// them by binary search and allocates nothing per frame. Lines are zero-based.

// GutterKind says what a gutter decoration marks; the Look maps it to a color.
type GutterKind uint8

const (
	// GutterAdded marks lines that are new.
	GutterAdded GutterKind = iota + 1
	// GutterModified marks lines that changed.
	GutterModified
	// GutterDeleted marks lines removed above StartLine: a zero-height mark between lines,
	// drawn as a small wedge at the top of StartLine. EndLine is ignored.
	GutterDeleted
)

// GutterDecoration marks the lines from StartLine to EndLine, both included, in the gutter's
// left margin.
type GutterDecoration struct {
	Kind               GutterKind
	StartLine, EndLine int
}

// GutterClick is a press on a decorated line of the gutter.
type GutterClick struct {
	// Line is the line, Kind the decoration that covers it.
	Line int
	Kind GutterKind
	// X and Y are the pointer's window position, and LineTop the window y of the top of the
	// line's first row, for a popup that hangs off the line.
	X, Y, LineTop float32
}

// LineAnnotation is a faint text after the end of a line, such as an inline blame. It is
// not part of the document: it is never selected, copied or measured for scrolling, and a line
// too long to measure cheaply shows none.
type LineAnnotation struct {
	Line int
	// Text must not change after it is handed over: the canvas keeps it across frames.
	Text string
	// Icon, when it is set, is drawn before the text in the text's color, two cells wide and a
	// cell away from it.
	Icon gfx.Icon
	// Rule continues the annotation with a hairline through the middle of its row to the right
	// edge of the text, as the row that stands for folded lines in a diff.
	Rule bool
}

const (
	// gutterBarX and gutterBarWidth place the decoration bar in the gutter.
	gutterBarX     = float32(2)
	gutterBarWidth = float32(3)
	// annotationLineLimit is the longest line, in bytes, that shows an annotation; measuring
	// where a longer one ends would cost more than the frame allows.
	annotationLineLimit = 4096
	// annotationGap is the cells between the end of a line and its annotation.
	annotationGap = 3
	// annotationIconCells is the cells an annotation's icon takes before its text: two for the
	// icon and one between it and the text.
	annotationIconCells = 3
)

// gutterState holds the decorations the host set.
type gutterState struct {
	decorations []GutterDecoration
	// maxEnd[i] is the largest line any of decorations[:i+1] reaches, so the first decoration
	// that can touch a line is found by search.
	maxEnd      []int
	clickable   bool
	onClick     func(GutterClick)
	annotations []LineAnnotation
}

// SetGutterDecorations replaces the gutter decorations. Decorations are kept sorted by
// StartLine; one with a negative start or an unknown kind is dropped. The slice is copied.
func (v *View) SetGutterDecorations(decorations []GutterDecoration) {
	g := &v.gutter
	g.decorations = g.decorations[:0]
	for _, d := range decorations {
		if d.StartLine < 0 || d.Kind < GutterAdded || d.Kind > GutterDeleted {
			continue
		}
		if d.Kind == GutterDeleted || d.EndLine < d.StartLine {
			d.EndLine = d.StartLine
		}
		g.decorations = append(g.decorations, d)
	}
	sort.SliceStable(g.decorations, func(i, j int) bool { return g.decorations[i].StartLine < g.decorations[j].StartLine })
	g.maxEnd = g.maxEnd[:0]
	reach := -1
	for _, d := range g.decorations {
		reach = max(reach, d.EndLine)
		g.maxEnd = append(g.maxEnd, reach)
	}
}

// SetGutterClick makes presses on decorated lines of the gutter call fn, while clickable is
// true. A press anywhere else in the gutter keeps placing the caret.
func (v *View) SetGutterClick(clickable bool, fn func(GutterClick)) {
	v.gutter.clickable, v.gutter.onClick = clickable, fn
}

// SetLineAnnotations replaces the line annotations, sorted by line; an entry with a negative
// line or no text is dropped. The slice is copied.
func (v *View) SetLineAnnotations(annotations []LineAnnotation) {
	g := &v.gutter
	g.annotations = g.annotations[:0]
	for _, a := range annotations {
		if a.Line >= 0 && a.Text != "" {
			g.annotations = append(g.annotations, a)
		}
	}
	sort.SliceStable(g.annotations, func(i, j int) bool { return g.annotations[i].Line < g.annotations[j].Line })
}

// decorationAt is the decoration that covers line, the last one set when several do.
func (g *gutterState) decorationAt(line int) (GutterDecoration, bool) {
	hi := sort.Search(len(g.decorations), func(i int) bool { return g.decorations[i].StartLine > line })
	for i := hi - 1; i >= 0 && g.maxEnd[i] >= line; i-- {
		if d := g.decorations[i]; d.EndLine >= line {
			return d, true
		}
	}
	return GutterDecoration{}, false
}

// gutterColor is the color of a decoration kind: the Look's, or a default when the theme sets
// none.
func gutterColor(look Look, kind GutterKind) gfx.Color {
	var c gfx.Color
	switch kind {
	case GutterAdded:
		c = look.GutterAdded
		if c.Alpha == 0 {
			c = gfx.RGB24(0x2EA043)
		}
	case GutterModified:
		c = look.GutterModified
		if c.Alpha == 0 {
			c = gfx.RGB24(0x3B76D1)
		}
	default:
		c = look.GutterDeleted
		if c.Alpha == 0 {
			c = gfx.RGB24(0xD13B3B)
		}
	}
	return c
}

// paintGutterDecorations draws the decorations that reach the lines firstLine to lastLine, in
// the gutter's clip.
func (v *View) paintGutterDecorations(canvas *gfx.Canvas, area gfx.Rect, look Look, firstLine, lastLine int) {
	g := &v.gutter
	if len(g.decorations) == 0 {
		return
	}
	lines := v.text.LineCount()
	hi := sort.Search(len(g.decorations), func(i int) bool { return g.decorations[i].StartLine > lastLine })
	lo := sort.Search(hi, func(i int) bool { return g.maxEnd[i] >= firstLine })
	for _, d := range g.decorations[lo:hi] {
		if d.EndLine < firstLine || d.StartLine >= lines {
			continue
		}
		top := area.Y + float32(v.lineRow(d.StartLine))*v.lineH - v.scroll
		color := gutterColor(look, d.Kind)
		if d.Kind == GutterDeleted {
			// A wedge between two lines: a bar as wide as the others, a few pixels tall,
			// centered on the line boundary.
			canvas.Fill(gfx.Rect{X: area.X + gutterBarX, Y: top - 2, Width: gutterBarWidth + 4, Height: 4}, color)
			continue
		}
		bottom := area.Y + float32(v.lineRowEnd(min(d.EndLine, lines-1)))*v.lineH - v.scroll
		canvas.Fill(gfx.Rect{X: area.X + gutterBarX, Y: top, Width: gutterBarWidth, Height: bottom - top}, color)
	}
}

// gutterPointer takes a press on a decorated line of the gutter. It reports whether the press
// was consumed.
func (v *View) gutterPointer(event gfx.PointerEvent) bool {
	g := &v.gutter
	if !g.clickable || g.onClick == nil || len(g.decorations) == 0 || event.Button != gfx.PointerButtonPrimary {
		return false
	}
	if event.X >= v.textLeft-textPad || event.X < v.area.X {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	row = min(max(row, 0), v.rowCount()-1)
	line, _ := v.rowLine(row)
	d, ok := g.decorationAt(line)
	if !ok {
		// A deletion mark sits at the top of its line, so a press just above a line's top row
		// is on it too.
		return false
	}
	if d.Kind == GutterDeleted && line != d.StartLine {
		return false
	}
	g.onClick(GutterClick{
		Line: line, Kind: d.Kind, X: event.X, Y: event.Y,
		LineTop: v.area.Y + float32(v.lineRow(line))*v.lineH - v.scroll,
	})
	return true
}

// paintAnnotation draws the annotation of line after its last row, if it has one. row is the
// line's last row and top the window y of it.
func (v *View) paintAnnotation(canvas *gfx.Canvas, l lineRef, row wrapRow, y float32, look Look, cursor *int) {
	g := &v.gutter
	n := len(g.annotations)
	if n == 0 || l.long || l.size > annotationLineLimit {
		return
	}
	// Lines are painted in order, so the cursor only moves forward; a scroll up starts again.
	i := *cursor
	if i >= n || (i > 0 && g.annotations[i-1].Line >= l.line) {
		i = sort.Search(n, func(k int) bool { return g.annotations[k].Line >= l.line })
	}
	for i < n && g.annotations[i].Line < l.line {
		i++
	}
	*cursor = i
	if i >= n || g.annotations[i].Line != l.line {
		return
	}
	note := &g.annotations[i]
	text := note.Text
	cells := 0
	for _, r := range text {
		cells += runeCells(r, 0)
	}
	if cells == 0 {
		return
	}
	lead := 0
	if note.Icon.ViewBox > 0 {
		lead = annotationIconCells
	}
	end := v.cellsAt(l, l.size) - row.cells
	x := v.textLeft + float32(end+annotationGap)*v.cellW - v.scrollX
	right := x + float32(lead+cells)*v.cellW
	if x >= v.textRight || (right <= v.textLeft && !note.Rule) {
		return
	}
	color := look.Subtle
	color.Alpha *= 0.75
	if lead > 0 {
		side := min(v.cellH, float32(lead-1)*v.cellW)
		canvas.DrawIcon(note.Icon, gfx.Rect{X: x, Y: y + (v.lineH-side)/2, Width: side, Height: side}, color)
	}
	style := gfx.TextStyle{Size: v.font.Size, Color: color, Mono: true, MonoFace: v.font.Face}
	run := [1]gfx.TextRun{{Bytes: int32(len(text)), Cells: int32(cells), Color: color}}
	rect := gfx.Rect{X: x + float32(lead)*v.cellW, Y: y + (v.lineH-v.cellH)/2, Width: float32(cells)*v.cellW + 1, Height: v.cellH}
	canvas.LabelRuns(text, rect, style, v.cellW, run[:])
	if note.Rule {
		from := max(right+v.cellW, v.textLeft)
		if from < v.textRight {
			rule := color
			rule.Alpha *= 0.5
			canvas.Fill(gfx.Rect{X: from, Y: float32(math.Floor(float64(y + v.lineH/2))), Width: v.textRight - from, Height: 1}, rule)
		}
	}
}
