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
	start, end := v.Selection()
	v.symbolSelection = Range{Start: start, End: end}
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

// BracketMatch holds one delimiter and its matching delimiter by byte offset.
type BracketMatch struct{ Offset, Mate uint32 }

type bracketClick struct {
	caret, revision int
	offsetPlusOne   int
}

// rememberBracketClick records the glyph under a click. The caret itself
// still snaps to the nearest edge, which can be shared by two brackets.
func (v *View) rememberBracketClick(x, y float32, caret int) {
	cell := max(v.cellW, 1)
	if x < v.textLeft-v.scrollX || y < v.area.Y || y >= v.area.Y+v.area.Height {
		return
	}
	if !v.bracketAt(caret) && !v.bracketAt(caret-1) {
		return
	}
	offset := v.offsetAt(x-cell/2, y)
	if (offset == caret || offset+1 == caret) && v.bracketAt(offset) {
		v.clickedBracket = bracketClick{caret: caret, revision: v.revision, offsetPlusOne: offset + 1}
	}
}

func (v *View) bracketAt(offset int) bool {
	if offset < 0 || offset >= v.text.Len() {
		return false
	}
	switch v.text.ByteAt(offset) {
	case '(', ')', '[', ']', '{', '}':
		return true
	}
	return false
}

// SetBracketMatches installs an immutable index ordered by Offset for this revision.
func (v *View) SetBracketMatches(matches []BracketMatch) {
	v.bracketRevision = v.revision
	v.bracketMatches = matches
}

func (v *View) caretBracketPair(selStart, selEnd int) (pair [2]int) {
	matches := v.bracketMatches
	if v.bracketRevision != v.revision || len(matches) == 0 || selStart != selEnd || v.preedit.Composing {
		return pair
	}
	target := v.caret
	click := v.clickedBracket
	clicked := click.offsetPlusOne != 0 && click.caret == target && click.revision == v.revision
	if clicked {
		target = click.offsetPlusOne - 1
	}
	at, found := slices.BinarySearchFunc(matches, uint32(target), func(match BracketMatch, offset uint32) int {
		return cmp.Compare(match.Offset, offset)
	})
	if !found {
		if clicked || at == 0 || int(matches[at-1].Offset)+1 != target {
			return pair
		}
		at--
	}
	offset, mate := int(matches[at].Offset), int(matches[at].Mate)
	return [2]int{min(offset, mate), max(offset, mate)}
}

func (v *View) paintContextHighlights(canvas *gfx.Canvas, l lineRef, p part, rowEnd, from, to, shift int, y float32, look Look, symbolRanges []Range, bracketPair [2]int) {
	first := l.start + p.row.at
	last := l.start + min(rowEnd, p.base+len(p.text))
	if len(symbolRanges) > 0 {
		// For an unwrapped short line, p still contains the entire line. Restrict
		// lookup to the horizontal viewport when the line can extend past it.
		if !l.long && !v.wrapping() && (from > 0 || last-first > to/2) {
			first = l.start + v.columnFrom(l, 0, l.size, 0, float32(from)-0.5)
			last = l.start + v.columnFrom(l, 0, l.size, 0, float32(to)+0.5)
		}
		i := sort.Search(len(symbolRanges), func(i int) bool { return symbolRanges[i].End > first })
		color := look.Foreground
		color.Alpha *= 0.14
		for ; i < len(symbolRanges) && symbolRanges[i].Start < last; i++ {
			r := symbolRanges[i]
			lo, hi := max(r.Start, first)-l.start, min(r.End, last)-l.start
			rect := v.contextHighlightRect(l, lo, hi, from, to, shift, y)
			if rect.Width > 0 {
				canvas.Fill(rect, color)
			}
		}
	}
	if bracketPair[0] < bracketPair[1] {
		fill, edge := look.Foreground, look.Foreground
		fill.Alpha *= 0.14
		edge.Alpha *= 0.55
		for _, at := range bracketPair {
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
