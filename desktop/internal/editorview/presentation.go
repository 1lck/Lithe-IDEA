package editorview

import (
	"sort"

	"github.com/vivaui/viva/gfx"
)

// Presentation contains native drawing choices already resolved by the owner.
// Its zero value preserves the existing appearance for embedded editor consumers.
type Presentation struct {
	HideLineNumbers    bool
	ShowWhitespace     bool
	CursorStyle        string
	DisableCursorBlink bool
}

func (v *View) SetPresentation(value Presentation) { v.presentation = value }

// SetSearchMatches installs Core's ordered byte ranges for this exact revision.
// A text edit invalidates their paint immediately, before a new worker can answer.
func (v *View) SetSearchMatches(matches []Range) {
	v.searchRanges = append(v.searchRanges[:0], matches...)
	v.searchRevision = v.revision
}

func (v *View) ClearSearchMatches() { v.searchRanges = nil }

func (v *View) paintSearchMatches(canvas *gfx.Canvas, l lineRef, p part, from, to, shift int, y float32, color gfx.Color) {
	if v.searchRevision != v.revision || len(v.searchRanges) == 0 {
		return
	}
	start, end := l.start+p.base, l.start+p.base+len(p.text)
	first := sort.Search(len(v.searchRanges), func(i int) bool { return v.searchRanges[i].End >= start })
	color.Alpha *= 0.45
	for i := first; i < len(v.searchRanges) && v.searchRanges[i].Start <= end; i++ {
		match := v.searchRanges[i]
		lo, hi := v.selectionCells(l, match.Start, match.End)
		if match.Start == match.End {
			lo = v.cellsAt(l, match.Start-l.start)
			hi = lo + 1
		}
		lo, hi = max(lo, from), min(hi, to)
		if hi <= lo {
			continue
		}
		x := v.textLeft + float32(lo-shift)*v.cellW - v.scrollX
		canvas.Fill(gfx.Rect{X: x, Y: y, Width: float32(hi-lo) * v.cellW, Height: v.lineH}, color)
	}
}

func (v *View) paintConfiguredCaret(canvas *gfx.Canvas, x, y float32, color gfx.Color) {
	rect := gfx.Rect{X: float32(int(x + 0.5)), Y: y, Width: 2, Height: v.lineH}
	switch v.presentation.CursorStyle {
	case "block":
		rect.Width = v.cellW
		color.Alpha *= 0.6
	case "underline":
		rect.Width = v.cellW
		rect.Y += v.lineH - 2
		rect.Height = 2
	}
	canvas.Fill(rect, color)
}

func (v *View) paintWhitespace(canvas *gfx.Canvas, r rune, cells, width, shift int, y float32) {
	if !v.presentation.ShowWhitespace || (r != ' ' && r != '\t') {
		return
	}
	x := v.textLeft + float32(cells-shift)*v.cellW - v.scrollX
	if r == ' ' {
		canvas.Fill(gfx.Rect{X: x + v.cellW/2 - 0.75, Y: y + v.lineH/2 - 0.75, Width: 1.5, Height: 1.5}, v.whitespaceColor)
	} else {
		canvas.Fill(gfx.Rect{X: x + 2, Y: y + v.lineH/2, Width: max(float32(width)*v.cellW-4, 1), Height: 1}, v.whitespaceColor)
		canvas.Fill(gfx.Rect{X: x + float32(width)*v.cellW - 4, Y: y + v.lineH/2 - 2, Width: 1, Height: 5}, v.whitespaceColor)
	}
}
