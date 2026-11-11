package editorview

import (
	"sort"

	"github.com/vivaui/viva/gfx"
)

// Code folding: the host gives the ranges of lines that can fold (a language server's or a
// plugin's folding ranges, or ones worked out from indentation), and the view keeps which of them
// are collapsed. A collapsed range keeps its first line and hides the lines after it up to its
// last; a hidden line takes no rows, so the layout that maps lines to rows (wrap.go) leaves it out
// of the scroll, the paint and the pointer without any of them knowing about folding. An arrow in
// the gutter folds and unfolds a range, a box after the first line's text stands for the hidden
// lines and unfolds them on a press, and a caret that lands on a hidden line unfolds what hides it.
// An edit moves the ranges below it and drops the ones it cut into; the host sends fresh ranges
// after it.

const (
	// foldWidth is the gutter column the arrows take, and foldIconSize an arrow's side.
	foldWidth    = float32(14)
	foldIconSize = float32(10)
	// foldPlaceholder is the text of the box that stands for hidden lines.
	foldPlaceholder = "…"
)

// FoldRange is a range of zero-based lines that can fold: StartLine stays shown and the lines
// after it up to EndLine are hidden while the range is collapsed.
type FoldRange struct {
	StartLine, EndLine int
}

// foldState is the view's folding.
type foldState struct {
	// ranges are the foldable ranges by start line, the longest first among those of one line.
	ranges []FoldRange
	// collapsed maps the start line of each collapsed range to its last line.
	collapsed map[int]int
	// hidden marks the hidden lines; nil while nothing is collapsed.
	hidden []bool
	// expanded and folded are the gutter arrows the host gave.
	expanded, folded gfx.Icon
	// x is where the arrow column starts, and boxes the placeholder boxes of the last paint.
	x     float32
	boxes []foldBox
}

// foldBox is a placeholder box as painted, so a press on it can unfold its line.
type foldBox struct {
	line int
	rect gfx.Rect
}

// SetFoldIcons gives the arrows the gutter shows for an expanded and a collapsed range.
func (v *View) SetFoldIcons(expanded, folded gfx.Icon) {
	v.fold.expanded, v.fold.folded = expanded, folded
}

// SetFoldRanges replaces the foldable ranges. A range collapsed before stays collapsed when a
// range still starts on its line; the others unfold. A range of one line, or one past the text,
// is left out.
func (v *View) SetFoldRanges(ranges []FoldRange) {
	f := &v.fold
	lines := v.text.LineCount()
	next := make([]FoldRange, 0, len(ranges))
	for _, r := range ranges {
		if r.StartLine >= 0 && r.EndLine > r.StartLine && r.EndLine < lines {
			next = append(next, r)
		}
	}
	sort.Slice(next, func(i, j int) bool {
		if next[i].StartLine != next[j].StartLine {
			return next[i].StartLine < next[j].StartLine
		}
		return next[i].EndLine > next[j].EndLine
	})
	next = dedupeFolds(next)
	f.ranges = next
	if len(f.collapsed) > 0 {
		kept := map[int]int{}
		for start := range f.collapsed {
			if r, ok := f.rangeAt(start); ok {
				kept[start] = r.EndLine
			}
		}
		f.collapsed = kept
		v.refold()
	}
}

// FoldRanges is a copy of the foldable ranges.
func (v *View) FoldRanges() []FoldRange { return append([]FoldRange(nil), v.fold.ranges...) }

// Folded reports whether the range starting on line is collapsed.
func (v *View) Folded(line int) bool {
	_, ok := v.fold.collapsed[line]
	return ok
}

// ToggleFold folds or unfolds the range that starts on line. It reports whether one does.
func (v *View) ToggleFold(line int) bool {
	f := &v.fold
	if _, ok := f.collapsed[line]; ok {
		delete(f.collapsed, line)
		v.refold()
		return true
	}
	r, ok := f.rangeAt(line)
	if !ok {
		return false
	}
	v.collapse(r)
	return true
}

// FoldAtCaret folds the innermost expanded range that holds the caret's line, and moves the caret
// to the end of the range's first line when it would be hidden.
func (v *View) FoldAtCaret() bool {
	line := v.text.LineOf(v.caret)
	f := &v.fold
	best, found := FoldRange{}, false
	for _, r := range f.ranges {
		if r.StartLine > line {
			break
		}
		if r.EndLine < line {
			continue
		}
		if _, folded := f.collapsed[r.StartLine]; folded {
			continue
		}
		if !found || r.EndLine-r.StartLine < best.EndLine-best.StartLine {
			best, found = r, true
		}
	}
	if !found {
		return false
	}
	v.collapse(best)
	return true
}

// UnfoldAtCaret unfolds the range collapsed on the caret's line, or the innermost collapsed one
// holding it.
func (v *View) UnfoldAtCaret() bool {
	line := v.text.LineOf(v.caret)
	f := &v.fold
	if _, ok := f.collapsed[line]; ok {
		delete(f.collapsed, line)
		v.refold()
		return true
	}
	best, found := -1, false
	for start, end := range f.collapsed {
		if start <= line && line <= end && (!found || start > best) {
			best, found = start, true
		}
	}
	if !found {
		return false
	}
	delete(f.collapsed, best)
	v.refold()
	return true
}

// FoldAll collapses every range.
func (v *View) FoldAll() {
	f := &v.fold
	if len(f.ranges) == 0 {
		return
	}
	if f.collapsed == nil {
		f.collapsed = map[int]int{}
	}
	for _, r := range f.ranges {
		f.collapsed[r.StartLine] = r.EndLine
	}
	v.refold()
	v.keepCaretShown()
}

// UnfoldAll expands every range.
func (v *View) UnfoldAll() {
	if len(v.fold.collapsed) == 0 {
		return
	}
	v.fold.collapsed = nil
	v.refold()
}

// collapse folds r and keeps the caret on a shown line.
func (v *View) collapse(r FoldRange) {
	f := &v.fold
	if f.collapsed == nil {
		f.collapsed = map[int]int{}
	}
	f.collapsed[r.StartLine] = r.EndLine
	v.refold()
	v.keepCaretShown()
}

// keepCaretShown moves a caret a fold hid to the end of the first line of the outermost range
// that hides it, the place IntelliJ IDEA leaves it.
func (v *View) keepCaretShown() {
	line := v.text.LineOf(v.caret)
	if !v.fold.hides(line) {
		return
	}
	outer := line
	for start, end := range v.fold.collapsed {
		if start < line && line <= end && start < outer {
			outer = start
		}
	}
	v.anchor, v.caret = v.text.LineEnd(outer), v.text.LineEnd(outer)
	v.moved()
}

// rangeAt is the longest range that starts on line.
func (f *foldState) rangeAt(line int) (FoldRange, bool) {
	i := sort.Search(len(f.ranges), func(k int) bool { return f.ranges[k].StartLine >= line })
	if i < len(f.ranges) && f.ranges[i].StartLine == line {
		return f.ranges[i], true
	}
	return FoldRange{}, false
}

// hides reports whether a collapsed range hides line.
func (f *foldState) hides(line int) bool {
	return line >= 0 && line < len(f.hidden) && f.hidden[line]
}

// refold marks the hidden lines again and lays the rows out for them.
func (v *View) refold() {
	f := &v.fold
	if len(f.collapsed) == 0 {
		f.collapsed, f.hidden = nil, nil
	} else {
		lines := v.text.LineCount()
		f.hidden = make([]bool, lines)
		for start, end := range f.collapsed {
			for line := start + 1; line <= min(end, lines-1); line++ {
				f.hidden[line] = true
			}
		}
	}
	clear(v.rowCache)
	if !v.mapped() {
		v.wraps, v.rowStart = v.wraps[:0], v.rowStart[:0]
		return
	}
	if len(v.wraps) == v.text.LineCount() {
		for line := range v.wraps {
			v.countRows(line)
		}
		v.rowsDirty = true
	}
}

// revealHiddenCaret unfolds every collapsed range that hides the caret's line. A move, a search
// match or a jump that lands there shows it.
func (v *View) revealHiddenCaret() {
	f := &v.fold
	if len(f.collapsed) == 0 {
		return
	}
	line := v.text.LineOf(v.caret)
	if !f.hides(line) {
		return
	}
	for start, end := range f.collapsed {
		if start < line && line <= end {
			delete(f.collapsed, start)
		}
	}
	v.refold()
}

// shiftFolds follows an edit that turned lines first to oldLast into first to newLast: ranges
// below it move, ranges that hold it grow or shrink, and ranges it cut into are dropped, as is
// a collapse whose hidden lines it changed.
func (v *View) shiftFolds(first, oldLast, newLast int) {
	f := &v.fold
	if len(f.ranges) == 0 && len(f.collapsed) == 0 {
		return
	}
	delta := newLast - oldLast
	move := func(r FoldRange) (FoldRange, bool) {
		switch {
		case r.EndLine < first:
			return r, true
		case r.StartLine > oldLast:
			return FoldRange{r.StartLine + delta, r.EndLine + delta}, true
		case r.StartLine <= first && r.EndLine >= oldLast:
			// The edit is inside the range, its first line included.
			r.EndLine += delta
			return r, r.EndLine > r.StartLine
		}
		return r, false
	}
	kept := f.ranges[:0]
	for _, r := range f.ranges {
		if moved, ok := move(r); ok {
			kept = append(kept, moved)
		}
	}
	f.ranges = kept
	if len(f.collapsed) > 0 {
		collapsed := map[int]int{}
		for start, end := range f.collapsed {
			// An edit that reaches a hidden line unfolds the range: its lines changed out of sight.
			if first <= end && oldLast > start {
				continue
			}
			if moved, ok := move(FoldRange{start, end}); ok {
				collapsed[moved.StartLine] = moved.EndLine
			}
		}
		f.collapsed = collapsed
	}
	v.refoldAfterEdit()
}

// refoldAfterEdit marks the hidden lines for the new text; the rows are laid out by the edit.
func (v *View) refoldAfterEdit() {
	f := &v.fold
	if len(f.collapsed) == 0 {
		f.collapsed, f.hidden = nil, nil
		return
	}
	lines := v.text.LineCount()
	f.hidden = make([]bool, lines)
	for start, end := range f.collapsed {
		for line := start + 1; line <= min(end, lines-1); line++ {
			f.hidden[line] = true
		}
	}
}

// dropFolds forgets every range, for a text that changed as a whole.
func (v *View) dropFolds() {
	v.fold.ranges, v.fold.collapsed, v.fold.hidden = nil, nil, nil
}

// dedupeFolds keeps one range per start line, the longest; ranges come sorted.
func dedupeFolds(ranges []FoldRange) []FoldRange {
	out := ranges[:0]
	for _, r := range ranges {
		if len(out) > 0 && out[len(out)-1].StartLine == r.StartLine {
			continue
		}
		out = append(out, r)
	}
	return out
}

// foldColumn is the width the arrow column takes: zero without ranges or arrows.
func (v *View) foldColumn() float32 {
	if len(v.fold.ranges) == 0 || v.fold.expanded.ViewBox <= 0 {
		return 0
	}
	return foldWidth
}

// paintFoldArrows draws the arrows of the ranges that start on lines firstLine to lastLine.
func (v *View) paintFoldArrows(canvas *gfx.Canvas, area gfx.Rect, look Look, firstLine, lastLine int) {
	f := &v.fold
	if v.foldColumn() == 0 {
		return
	}
	side := min(v.lineH-2, foldIconSize)
	i := sort.Search(len(f.ranges), func(k int) bool { return f.ranges[k].StartLine >= firstLine })
	for ; i < len(f.ranges) && f.ranges[i].StartLine <= lastLine; i++ {
		line := f.ranges[i].StartLine
		if f.hides(line) {
			continue
		}
		icon, color := f.expanded, look.Subtle
		color.Alpha *= 0.6
		if _, folded := f.collapsed[line]; folded {
			icon, color = f.folded, look.Subtle
		}
		top := area.Y + float32(v.lineRow(line))*v.lineH - v.scroll
		canvas.DrawIcon(icon, gfx.Rect{X: f.x + (foldWidth-side)/2, Y: top + (v.lineH-side)/2, Width: side, Height: side}, color)
	}
}

// paintFoldBox draws the box that stands for the hidden lines after line's text, on its last row
// at y, and records it for presses. It returns how many cells the box takes, so an annotation can
// go after it.
func (v *View) paintFoldBox(canvas *gfx.Canvas, l lineRef, row wrapRow, y float32, look Look) int {
	if _, folded := v.fold.collapsed[l.line]; !folded {
		return 0
	}
	end := v.cellsAt(l, l.size) - row.cells
	x := v.textLeft + float32(end+1)*v.cellW - v.scrollX
	cells := 3
	rect := gfx.Rect{X: x, Y: y + (v.lineH-v.cellH)/2, Width: float32(cells) * v.cellW, Height: v.cellH}
	if rect.X >= v.textRight || rect.X+rect.Width <= v.textLeft {
		return cells + 1
	}
	box := look.Selection
	box.Alpha *= 0.5
	canvas.Rounded(rect, 3, box)
	style := gfx.TextStyle{Size: v.font.Size, Color: look.Subtle, Mono: true, MonoFace: v.font.Face}
	run := [1]gfx.TextRun{{Bytes: int32(len(foldPlaceholder)), Cells: 1, Color: look.Subtle}}
	canvas.LabelRuns(foldPlaceholder, gfx.Rect{X: rect.X + v.cellW, Y: rect.Y, Width: v.cellW + 1, Height: v.cellH}, style, v.cellW, run[:])
	v.fold.boxes = append(v.fold.boxes, foldBox{line: l.line, rect: rect})
	return cells + 1
}

// foldPointer takes a press on an arrow or a placeholder box. It reports whether the press was
// consumed.
func (v *View) foldPointer(event gfx.PointerEvent) bool {
	f := &v.fold
	if event.Button != gfx.PointerButtonPrimary {
		return false
	}
	for _, box := range f.boxes {
		if event.X >= box.rect.X && event.X < box.rect.X+box.rect.Width && event.Y >= box.rect.Y && event.Y < box.rect.Y+box.rect.Height {
			v.ToggleFold(box.line)
			return true
		}
	}
	if v.foldColumn() == 0 || event.X < f.x || event.X >= f.x+foldWidth {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	row = min(max(row, 0), v.rowCount()-1)
	line, _ := v.rowLine(row)
	return v.ToggleFold(line)
}

// IndentFoldRanges works out folding ranges from indentation, for a text no language server or
// plugin gives ranges for: a line folds the lines after it that are indented deeper, and a closing
// bracket line at its own indentation right after them, so a block folds to "{…}". Blank lines
// inside a block belong to it. tab is the columns a tab stands for.
func IndentFoldRanges(text []byte, tab int) []FoldRange {
	type lineInfo struct {
		indent int
		blank  bool
		closer bool
	}
	var lines []lineInfo
	start := 0
	for i := 0; i <= len(text); i++ {
		if i < len(text) && text[i] != '\n' {
			continue
		}
		line := text[start:i]
		indent, k := 0, 0
		for ; k < len(line); k++ {
			switch line[k] {
			case ' ':
				indent++
				continue
			case '\t':
				indent += tab - indent%tab
				continue
			}
			break
		}
		rest := line[k:]
		for len(rest) > 0 && (rest[len(rest)-1] == '\r' || rest[len(rest)-1] == ' ' || rest[len(rest)-1] == '\t') {
			rest = rest[:len(rest)-1]
		}
		info := lineInfo{indent: indent, blank: len(rest) == 0}
		if !info.blank {
			switch rest[0] {
			case '}', ')', ']':
				info.closer = true
			}
		}
		lines = append(lines, info)
		start = i + 1
	}
	var ranges []FoldRange
	// open holds the lines whose blocks are still open, innermost last.
	var open []int
	lastShown := -1
	closeTo := func(indent, at int, closer bool) {
		for len(open) > 0 && lines[open[len(open)-1]].indent >= indent {
			startLine := open[len(open)-1]
			open = open[:len(open)-1]
			end := lastShown
			if closer && lines[startLine].indent == indent {
				end = at
			}
			if end > startLine {
				ranges = append(ranges, FoldRange{StartLine: startLine, EndLine: end})
			}
			closer = false
		}
	}
	for i, info := range lines {
		if info.blank {
			continue
		}
		closeTo(info.indent, i, info.closer)
		open = append(open, i)
		lastShown = i
	}
	closeTo(-1, len(lines), false)
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].StartLine < ranges[j].StartLine })
	return ranges
}
