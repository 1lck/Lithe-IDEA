package editorview

import (
	"math"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/vivaui/viva/gfx"
)

// IndentGuideScope is a paired block delimiter, in UTF-8 byte offsets.
type IndentGuideScope struct{ Open, Close int }

type indentScopeGuide struct {
	IndentGuideScope
	first, end, column int
	parent, depth      int
	outerColumn        int
}

// PreparedIndentGuideScopes contains geometry for one immutable document snapshot.
type PreparedIndentGuideScopes struct {
	text   rope.Rope
	guides []indentScopeGuide
}

// PrepareIndentGuideScopes projects ordered, nested pairs off the window thread.
func PrepareIndentGuideScopes(text rope.Rope, scopes []IndentGuideScope) PreparedIndentGuideScopes {
	prepared := PreparedIndentGuideScopes{text: text}
	for _, scope := range scopes {
		if scope.Open < 0 || scope.Open >= scope.Close || scope.Close >= text.Len() {
			continue
		}
		openLine, closeLine := text.LineOf(scope.Open), text.LineOf(scope.Close)
		if closeLine <= openLine+1 {
			continue
		}
		start := text.LineStart(closeLine)
		column, leading := ropeGuideIndent(text, start, scope.Close)
		if !leading {
			// A closer after code inherits the block opener's indentation.
			column, _ = ropeGuideIndent(text, text.LineStart(openLine), scope.Open)
		}
		parent := len(prepared.guides) - 1
		for parent >= 0 && prepared.guides[parent].Close < scope.Close {
			parent = prepared.guides[parent].parent
		}
		depth, outerColumn := 0, column
		if parent >= 0 {
			depth = prepared.guides[parent].depth + 1
			outerColumn = min(outerColumn, prepared.guides[parent].outerColumn)
		}
		prepared.guides = append(prepared.guides, indentScopeGuide{
			IndentGuideScope: scope, first: openLine + 1, end: closeLine,
			column: column, parent: parent, depth: depth, outerColumn: outerColumn,
		})
	}
	return prepared
}

func (v *View) SetIndentGuideScopes(prepared PreparedIndentGuideScopes) {
	if len(prepared.guides) == 0 || prepared.text.Same(v.text) {
		v.indentGuideScopes = prepared.guides
		v.indentGuideRevision = v.revision
	}
}

func activeIndentScope(scopes []indentScopeGuide, caret int) int {
	i := sort.Search(len(scopes), func(i int) bool { return scopes[i].Open >= caret }) - 1
	for i >= 0 && scopes[i].Close < caret {
		i = scopes[i].parent
	}
	return i
}

func indentScopeAtLine(scopes []indentScopeGuide, line int) int {
	i := sort.Search(len(scopes), func(i int) bool { return scopes[i].first > line }) - 1
	for i >= 0 && scopes[i].end <= line {
		i = scopes[i].parent
	}
	return i
}

const (
	// Limit work on malformed input with a very long whitespace prefix.
	indentGuideMaxCells = 1024
	// A blank run only borrows guides from reasonably close surrounding code.
	indentGuideContext = 32
)

// indentGuideGap caches the neighboring indentation across a run of blank rows in one frame.
type indentGuideGap struct {
	before     int
	haveBefore bool
	through    int
	cells      int
}

func (v *View) indentGuideCells(l lineRef, gap *indentGuideGap) int {
	cells, blank := leadingGuideIndent(l.text, 0)
	if l.long {
		cells, blank = ropeGuideIndent(v.text, l.start, l.start+l.size)
	}
	if !blank {
		gap.before, gap.haveBefore = cells, true
		return cells
	}
	if l.line >= gap.through {
		if !gap.haveBefore {
			_, gap.before = v.guideNeighbor(l.line, -1)
			gap.haveBefore = true
		}
		next, after := v.guideNeighbor(l.line, 1)
		gap.through = next
		gap.cells = min(gap.before, after)
	}
	return gap.cells
}

type fallbackIndentGuide struct {
	revision, caretLine, unit int
	first, last, depth        int
}

func (v *View) fallbackActiveGuide(line, unit int) fallbackIndentGuide {
	if old := v.indentGuideActive; old.unit == unit && old.revision == v.revision && old.caretLine == line {
		return old
	}
	guide := fallbackIndentGuide{revision: v.revision, caretLine: line, unit: unit, first: line, last: line}
	var gap indentGuideGap
	guide.depth = v.indentGuideCells(v.ref(line), &gap) / unit
	if guide.depth > 0 {
		limit := guide.depth * unit
		for _, direction := range [...]int{-1, 1} {
			for adjacent, walked := line+direction, 0; adjacent >= 0 && adjacent < v.text.LineCount() && walked < indentGuideContext; adjacent, walked = adjacent+direction, walked+1 {
				cells, blank := ropeGuideIndent(v.text, v.text.LineStart(adjacent), v.text.LineEnd(adjacent))
				if !blank && cells < limit {
					break
				}
				if direction < 0 {
					guide.first = adjacent
				} else {
					guide.last = adjacent
				}
			}
		}
	}
	v.indentGuideActive = guide
	return guide
}

func (v *View) guideNeighbor(line, direction int) (int, int) {
	for range indentGuideContext {
		line += direction
		if line < 0 || line >= v.text.LineCount() {
			break
		}
		if cells, blank := ropeGuideIndent(v.text, v.text.LineStart(line), v.text.LineEnd(line)); !blank {
			return line, cells
		}
	}
	return line, 0
}

func ropeGuideIndent(text rope.Rope, start, end int) (cells int, blank bool) {
	blank = true
	text.Chunks(start, min(end, start+indentGuideMaxCells), func(chunk string) bool {
		cells, blank = leadingGuideIndent(chunk, cells)
		return blank
	})
	return cells, blank
}

func leadingGuideIndent(text string, cells int) (int, bool) {
	for i := range len(text) {
		switch text[i] {
		case ' ':
			cells++
		case '\t':
			cells += tabSize - cells%tabSize
		case '\r':
			continue
		default:
			return cells, false
		}
		if cells >= indentGuideMaxCells {
			return indentGuideMaxCells, false
		}
	}
	return cells, true
}

func (v *View) paintIndentGuides(canvas *gfx.Canvas, cells, unit, active, from, to, shift int, y float32, neutral gfx.Color) {
	for depth, last := from/unit+1, min(cells, to)/unit; depth <= last; depth++ {
		v.paintIndentGuide(canvas, depth*unit, depth-1, shift, y, neutral, depth == active)
	}
}

func (v *View) paintScopeGuides(canvas *gfx.Canvas, scopes []indentScopeGuide, at, active, unit, fallbackDepth, from, to, shift int, y float32, neutral gfx.Color) {
	previousColumn := to
	depthOffset := max(0, (scopes[at].outerColumn-1)/unit)
	for at >= 0 {
		guide := scopes[at]
		if guide.column >= from && guide.column < previousColumn {
			highlight := at == active || (fallbackDepth > 0 && guide.column == fallbackDepth*unit)
			v.paintIndentGuide(canvas, guide.column, depthOffset+guide.depth, shift, y, neutral, highlight)
			previousColumn = guide.column
		}
		at = guide.parent
	}
}

func (v *View) paintIndentGuide(canvas *gfx.Canvas, column, depth, shift int, y float32, color gfx.Color, active bool) {
	if len(v.indentGuideColors) > 0 {
		color = v.indentGuideColors[depth%len(v.indentGuideColors)]
	}
	if active {
		color.Alpha = min(color.Alpha*2.8, 0.9)
	}
	x := v.textLeft + float32(column-shift)*v.cellW - v.scrollX
	canvas.Fill(gfx.Rect{X: float32(math.Floor(float64(x))) - 1, Y: y, Width: 1, Height: v.lineH}, color)
}
