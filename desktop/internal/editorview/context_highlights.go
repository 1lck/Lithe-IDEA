package editorview

import (
	"cmp"
	"slices"
	"sort"

	"github.com/vivaui/viva/gfx"
)

// SetSymbolHighlights installs reference backgrounds for the current text revision.
func (v *View) SetSymbolHighlights(ranges []Range) {
	v.symbolRevision = v.revision
	v.symbolSelection = span{anchor: v.anchor, caret: v.caret}
	if len(ranges) == 0 {
		v.symbolRanges = nil
		return
	}
	v.symbolRanges = append(v.symbolRanges[:0], ranges...)
	slices.SortFunc(v.symbolRanges, func(a, b Range) int { return cmp.Compare(a.Start, b.Start) })
	// Keep disjoint ranges so the visible window can binary-search their ends.
	n := 0
	for _, r := range v.symbolRanges {
		if r.Start < 0 || r.End <= r.Start || r.End > v.text.Len() {
			continue
		}
		if n > 0 && v.symbolRanges[n-1].End > r.Start {
			v.symbolRanges[n-1].End = max(v.symbolRanges[n-1].End, r.End)
			continue
		}
		v.symbolRanges[n] = r
		n++
	}
	v.symbolRanges = v.symbolRanges[:n]
}

// SetBracketHighlights installs both ends of the pair. A negative offset clears it.
func (v *View) SetBracketHighlights(open, close int) {
	v.bracketRevision = v.revision
	v.bracketPair = [2]int{}
	if open >= 0 && open < close && close < v.text.Len() {
		v.bracketPair = [2]int{open, close}
	}
}

func (v *View) paintContextHighlights(canvas *gfx.Canvas, l lineRef, p part, rowEnd, from, to, shift int, y float32, look Look) {
	first := l.start + p.row.at
	last := l.start + min(rowEnd, p.base+len(p.text))
	if v.symbolRevision == v.revision && len(v.symbolRanges) > 0 &&
		v.symbolSelection == (span{anchor: v.anchor, caret: v.caret}) {
		ranges := v.symbolRanges
		// For an unwrapped short line, p still contains the entire line. Restrict
		// lookup to the horizontal viewport when the line can extend past it.
		if !l.long && !v.wrapping() && (from > 0 || last-first > to/2) {
			first = l.start + v.columnFrom(l, 0, l.size, 0, float32(from)-0.5)
			last = l.start + v.columnFrom(l, 0, l.size, 0, float32(to)+0.5)
		}
		i := sort.Search(len(ranges), func(i int) bool { return ranges[i].End > first })
		color := look.Foreground
		color.Alpha *= 0.14
		for ; i < len(ranges) && ranges[i].Start < last; i++ {
			r := ranges[i]
			lo, hi := max(r.Start, first)-l.start, min(r.End, last)-l.start
			rect := v.contextHighlightRect(l, lo, hi, from, to, shift, y)
			if rect.Width > 0 {
				canvas.Fill(rect, color)
			}
		}
	}
	if v.bracketRevision == v.revision && v.bracketPair[0] < v.bracketPair[1] {
		fill, edge := look.Foreground, look.Foreground
		fill.Alpha *= 0.14
		edge.Alpha *= 0.55
		for _, at := range v.bracketPair {
			if at < first || at >= last {
				continue
			}
			rect := v.contextHighlightRect(l, at-l.start, at-l.start+1, from, to, shift, y)
			if rect.Width > 0 {
				canvas.Fill(rect, fill)
				canvas.Fill(gfx.Rect{X: rect.X, Y: rect.Y + rect.Height - 1, Width: rect.Width, Height: 1}, edge)
			}
		}
	}
}

func (v *View) contextHighlightRect(l lineRef, start, end, from, to, shift int, y float32) gfx.Rect {
	lo := max(v.cellsAt(l, start), from)
	endCell := v.cellsAt(l, end)
	for _, hint := range v.lineInlayHints(l.line) {
		if hint.byteCol == end {
			endCell = min(endCell, hint.cell)
		}
	}
	hi := min(endCell, to)
	return gfx.Rect{
		X:      v.textLeft + float32(lo-shift)*v.cellW - v.scrollX,
		Y:      y,
		Width:  float32(hi-lo) * v.cellW,
		Height: v.lineH,
	}
}
