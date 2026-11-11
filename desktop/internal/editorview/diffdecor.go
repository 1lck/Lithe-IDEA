package editorview

import (
	"sort"

	"github.com/vivaui/viva/gfx"
)

// Line highlights, line labels and the scroll of the view, for a host that shows two views side
// by side and keeps them in step, as a diff viewer does: it tints the lines that changed, numbers
// each side's lines as they were in its version of the file, and scrolls one side to match the
// other. Like the gutter decorations, the highlights in view are found by binary search and a
// paint allocates nothing for them. Lines are zero-based.

// LineHighlight tints the lines from StartLine to EndLine, both included, across the gutter and
// the text, under the caret's line band and the text.
//
// A Boundary highlight is a rule one point high at the top of StartLine instead, for a place
// between two lines, such as where the other side of a diff has lines this side has not. Its
// EndLine is ignored, and its StartLine may be the line count: the bottom of the last line.
type LineHighlight struct {
	StartLine, EndLine int
	Color              gfx.Color
	Boundary           bool
}

// decorState is what the host set: the highlights, the labels that replace the line numbers,
// and a line to scroll to the middle of the view.
type decorState struct {
	highlights []LineHighlight
	// maxEnd[i] is the largest line any of highlights[:i+1] reaches, so the first highlight that
	// can touch a line is found by search.
	maxEnd []int
	// labelled says labels replace the line numbers, and labelCells is the widest of them.
	labelled   bool
	labels     []string
	labelCells int
	// center is the line, plus one, that the next paint scrolls to the middle of the view; 0
	// asks for nothing.
	center int
	// noVerticalBar leaves the vertical scrollbar out.
	noVerticalBar bool
}

// SetLineHighlights replaces the line highlights. They are kept sorted by StartLine; one with a
// negative start or a transparent color is dropped. The slice is copied.
func (v *View) SetLineHighlights(highlights []LineHighlight) {
	d := &v.decor
	d.highlights = d.highlights[:0]
	for _, h := range highlights {
		if h.StartLine < 0 || h.Color.Alpha == 0 {
			continue
		}
		if h.Boundary || h.EndLine < h.StartLine {
			h.EndLine = h.StartLine
		}
		d.highlights = append(d.highlights, h)
	}
	sort.SliceStable(d.highlights, func(i, j int) bool { return d.highlights[i].StartLine < d.highlights[j].StartLine })
	d.maxEnd = d.maxEnd[:0]
	reach := -1
	for _, h := range d.highlights {
		reach = max(reach, h.EndLine)
		d.maxEnd = append(d.maxEnd, reach)
	}
}

// SetLineLabels shows labels[i] in the gutter in place of the number of line i. A label is ASCII,
// one cell a byte; an empty label, or a line past the end of labels, shows none. The gutter is as
// wide as the widest label. Nil shows the line numbers again. The slice is copied, and the labels
// must not change after they are handed over: the canvas keeps them across frames.
func (v *View) SetLineLabels(labels []string) {
	d := &v.decor
	if labels == nil {
		d.labelled, d.labels, d.labelCells = false, nil, 0
		return
	}
	d.labelled = true
	d.labels = append(d.labels[:0], labels...)
	d.labelCells = 0
	for _, label := range labels {
		d.labelCells = max(d.labelCells, len(label))
	}
}

// lineLabel is what the gutter shows for line: its label while labels are set, else its number.
func (v *View) lineLabel(line int) string {
	d := &v.decor
	if !d.labelled {
		return v.numberText.number(line)
	}
	if line < len(d.labels) {
		return d.labels[line]
	}
	return ""
}

// gutterDigits is how many cells the gutter's labels take: the widest label while labels are
// set, else the digits of the last line's number, and at least two either way.
func (v *View) gutterDigits(lines int) int {
	if v.decor.labelled {
		return max(v.decor.labelCells, 2)
	}
	return max(decimalDigits(lines), 2)
}

// ScrollOffset is how far the text is scrolled, in pixels: sideways and down.
func (v *View) ScrollOffset() (x, y float32) { return v.scrollX, v.scroll }

// SetScrollOffset scrolls the text to x and y, in pixels. Once the view was painted the offsets
// are kept in range at once; before, the first paint keeps them in range.
func (v *View) SetScrollOffset(x, y float32) {
	v.scrollX, v.scroll = x, y
	if v.painted {
		v.clampScroll()
	}
}

// LineHeight is the height of a row in the last paint, in pixels; 0 before the first paint.
func (v *View) LineHeight() float32 { return v.lineH }

// LineTop is the window y of the top of line's first row, at the last paint's place and the
// current scroll. A line at or past the line count is the bottom of the last line.
func (v *View) LineTop(line int) float32 {
	row := 0
	switch {
	case line >= v.text.LineCount():
		row = v.rowCount()
	case line > 0:
		row = v.lineRow(line)
	}
	return v.area.Y + float32(row)*v.lineH - v.scroll
}

// LineAt is the line at window y, at the current scroll. It reports false before the first paint
// and for a y above the first row or below the last.
func (v *View) LineAt(y float32) (int, bool) {
	if !v.painted || v.lineH <= 0 {
		return 0, false
	}
	at := y - v.area.Y + v.scroll
	if at < 0 {
		return 0, false
	}
	row := int(at / v.lineH)
	if row >= v.rowCount() {
		return 0, false
	}
	line, _ := v.rowLine(row)
	return line, true
}

// CenterLine asks the next paint to scroll line to the middle of the view, as far as the scroll
// reaches. It replaces a CenterLine not painted yet, and the paint does it after it brought the
// caret into view, so it wins over that.
func (v *View) CenterLine(line int) { v.decor.center = max(line, 0) + 1 }

// applyCenter does what CenterLine asked, in a paint that measured the rows.
func (v *View) applyCenter() {
	d := &v.decor
	if d.center == 0 {
		return
	}
	line := min(d.center-1, v.text.LineCount()-1)
	d.center = 0
	v.scroll = float32(v.lineRow(line))*v.lineH + v.lineH/2 - v.rowsHeight()/2
}

// paintHighlights fills the highlights that reach the lines firstLine to lastLine, across the
// gutter and the text, from the area's left edge to right.
func (v *View) paintHighlights(canvas *gfx.Canvas, right float32, firstLine, lastLine int) {
	d := &v.decor
	if len(d.highlights) == 0 {
		return
	}
	area := v.area
	lines := v.text.LineCount()
	width := right - area.X
	canvas.Clip(gfx.Rect{X: area.X, Y: area.Y, Width: width, Height: area.Height})
	// A boundary at the top of the line after the last in view is the bottom of the view.
	hi := sort.Search(len(d.highlights), func(i int) bool { return d.highlights[i].StartLine > lastLine+1 })
	lo := sort.Search(hi, func(i int) bool { return d.maxEnd[i] >= firstLine })
	for _, h := range d.highlights[lo:hi] {
		if h.EndLine < firstLine {
			continue
		}
		if h.Boundary {
			y := v.LineTop(h.StartLine)
			if h.StartLine >= lines {
				// The bottom of the last line: the rule is drawn inside the line, not under it.
				y--
			}
			canvas.Fill(gfx.Rect{X: area.X, Y: y, Width: width, Height: 1}, h.Color)
			continue
		}
		if h.StartLine >= lines {
			continue
		}
		top := v.LineTop(h.StartLine)
		bottom := area.Y + float32(v.lineRowEnd(min(h.EndLine, lines-1)))*v.lineH - v.scroll
		canvas.Fill(gfx.Rect{X: area.X, Y: top, Width: width, Height: bottom - top}, h.Color)
	}
	canvas.Unclip()
}

// BindWithoutMinimap is Bind for a view that never shows the minimap, as a side of a diff: the
// minimap and the button that shows it are left out of the hits, so the scrollbar offers no such
// button. Parts 0 and 1 of the scope stay free for the host.
func (v *View) BindWithoutMinimap(hit gfx.ID, parts gfx.Scope) {
	v.Bind(hit, parts)
	v.cfg.MinimapID, v.cfg.MinimapToggleID = gfx.ID{}, gfx.ID{}
	v.minimap = false
}

// HideVerticalBar leaves the vertical scrollbar out, for a view another view's bar scrolls, as
// the before side of a diff that follows the after side: the text reaches the right edge, and the
// wheel and the keys still scroll it.
func (v *View) HideVerticalBar() { v.decor.noVerticalBar = true }

// ShowContent replaces the text of a read-only view the host builds itself, as a side of a diff
// it lays out again when the user unfolds lines: unlike Reload it keeps no undo step, since the
// user never edited the text. The scroll stays; the caret stays at its byte offset, kept in range.
func (v *View) ShowContent(content Content) {
	if v.preedit.Composing {
		return
	}
	v.replaceFromDisk(content)
	v.undo, v.redo = nil, nil
}
