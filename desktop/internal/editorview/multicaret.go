package editorview

import (
	"slices"
	"strings"

	"github.com/vivaui/viva/gfx"
)

// Several carets, as IntelliJ IDEA has them. The primary selection is the view's anchor and
// caret, which everything that reads one selection (the status bar, find, the language
// server's requests, Vim) keeps using; the others are extra. Typing, deleting, Enter, Tab,
// pasting and the moving keys act at every caret: the single-caret code runs once per
// selection, from the last to the first so the offsets before each stay true, and the
// edits make one undo step. Selections that come to touch merge.
//
// The carets are added with Alt+Shift+click (a click on a caret takes it away), with Alt
// and a drag (one selection per line, a column selection), and with the occurrence and clone
// commands of the shortcut catalog (shortcuts.go): Add Selection for Next Occurrence, which first
// selects the word at the caret, Select All Occurrences, Unselect Occurrence and Clone Caret
// Above and Below. Escape goes back to one caret, as
// does a plain click, Select All, a move to a line and any edit the view did not make at every
// caret.

// span is one selection: its anchor and its caret.
type span struct{ anchor, caret int }

func (s span) lo() int { return min(s.anchor, s.caret) }
func (s span) hi() int { return max(s.anchor, s.caret) }

// HasExtraCarets reports whether more than one caret is in the view.
func (v *View) HasExtraCarets() bool { return len(v.extra) > 0 }

// ClearExtraCarets goes back to the primary caret alone.
func (v *View) ClearExtraCarets() {
	if len(v.extra) > 0 {
		v.extra = nil
		v.blinkFrom = v.clock
	}
}

// spans lists every selection in text order and says which one is the primary.
func (v *View) spans() ([]span, int) {
	all := make([]span, 0, len(v.extra)+1)
	all = append(all, v.extra...)
	all = append(all, span{v.anchor, v.caret})
	slices.SortStableFunc(all, func(a, b span) int { return a.lo() - b.lo() })
	primary := slices.Index(all, span{v.anchor, v.caret})
	return all, primary
}

// setSpans makes all the view's selections, primary the index of the primary one. Selections
// that overlap or touch merge; the merged one is primary when either was.
func (v *View) setSpans(all []span, primary int) {
	size := v.text.Len()
	merged := make([]span, 0, len(all))
	mergedPrimary := 0
	for i, s := range all {
		s.anchor, s.caret = min(max(s.anchor, 0), size), min(max(s.caret, 0), size)
		if n := len(merged); n > 0 {
			last := merged[n-1]
			if s.lo() < last.hi() || s.lo() == last.hi() && (s.lo() == s.hi() || last.lo() == last.hi()) {
				lo, hi := last.lo(), max(last.hi(), s.hi())
				if last.caret < last.anchor {
					merged[n-1] = span{hi, lo}
				} else {
					merged[n-1] = span{lo, hi}
				}
				if i == primary {
					mergedPrimary = n - 1
				}
				continue
			}
		}
		if i == primary {
			mergedPrimary = len(merged)
		}
		merged = append(merged, s)
	}
	p := merged[mergedPrimary]
	v.anchor, v.caret = p.anchor, p.caret
	v.extra = append(v.extra[:0], merged[:mergedPrimary]...)
	v.extra = append(v.extra, merged[mergedPrimary+1:]...)
	if len(v.extra) == 0 {
		v.extra = nil
	}
}

// eachCaret runs op once for every selection, with that selection as the view's own, from the
// last to the first; the edits it makes are one undo step. It reports whether op said it acted.
func (v *View) eachCaret(op func() bool) bool {
	all, primary := v.spans()
	if !v.multiEdit {
		// The undo step the edits make restores every selection as it was before them.
		v.multiEdit, v.multiUndo, v.multiBefore = true, false, v.snapshot()
		defer func() { v.multiEdit = false }()
	}
	goal := v.goal
	acted := false
	out := make([]span, len(all))
	for i := len(all) - 1; i >= 0; i-- {
		v.anchor, v.caret = all[i].anchor, all[i].caret
		v.extra = nil
		if i == primary {
			v.goal = goal
		} else {
			v.goal = -1
		}
		before := v.text.Len()
		if op() {
			acted = true
		}
		delta := v.text.Len() - before
		out[i] = span{v.anchor, v.caret}
		if i == primary {
			goal = v.goal
		}
		for j := i + 1; j < len(out); j++ {
			out[j].anchor += delta
			out[j].caret += delta
		}
	}
	v.setSpans(out, primary)
	v.goal = goal
	v.moved()
	v.goal = goal
	return acted
}

// multiKey runs a key at every caret, when there is more than one. Escape goes back to one.
func (v *View) multiKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	if len(v.extra) == 0 {
		return gfx.EventResult{}, false
	}
	if event.Key == gfx.KeyEscape {
		v.ClearExtraCarets()
		v.moved()
		return handled, true
	}
	var result gfx.EventResult
	ok := v.eachCaret(func() bool {
		r, took := v.key(event)
		if took {
			result = r
		}
		return took
	})
	return result, ok
}

// insertAll puts text in place of every selection. A paste of as many lines as there are
// carets gives each caret its own line.
func (v *View) insertAll(text string, kind editKind, paste bool) {
	parts := []string(nil)
	if paste {
		lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
		if len(lines) == len(v.extra)+1 {
			parts = lines
		}
	}
	all, _ := v.spans()
	index := len(all)
	v.eachCaret(func() bool {
		index--
		piece := text
		if parts != nil {
			piece = parts[index]
		}
		v.insert(piece, kind)
		return true
	})
}

// selectedTexts is the text of every selection, in text order, one per line.
func (v *View) selectedTexts() string {
	all, _ := v.spans()
	parts := make([]string, 0, len(all))
	for _, s := range all {
		parts = append(parts, string(v.text.AppendRange(nil, s.lo(), s.hi())))
	}
	return strings.Join(parts, "\n")
}

// toggleCaret adds a caret at offset, or takes away the one there.
func (v *View) toggleCaret(offset int) {
	all, primary := v.spans()
	for i, s := range all {
		if s.lo() <= offset && offset <= s.hi() && len(all) > 1 {
			all = slices.Delete(all, i, i+1)
			if i == primary {
				primary = len(all) - 1
			} else if i < primary {
				primary--
			}
			v.setSpans(all, primary)
			v.moved()
			return
		}
	}
	all = append(all, span{offset, offset})
	slices.SortStableFunc(all, func(a, b span) int { return a.lo() - b.lo() })
	v.setSpans(all, slices.Index(all, span{offset, offset}))
	v.moved()
}

// columnSelect selects, on every line from the one of from to the one of to, the columns
// between theirs: a column selection made by a drag with Alt.
func (v *View) columnSelect(fromX, fromY, toX, toY float32) {
	fromRow := v.rowAt(fromY)
	toRow := v.rowAt(toY)
	fromCells := max((fromX-v.textLeft+v.scrollX)/max(v.cellW, 1), 0)
	toCells := max((toX-v.textLeft+v.scrollX)/max(v.cellW, 1), 0)
	step := 1
	if toRow < fromRow {
		step = -1
	}
	var all []span
	for row := fromRow; ; row += step {
		line, sub := v.rowLine(row)
		start := v.text.LineStart(line)
		a := start + v.columnOnRow(line, sub, fromCells)
		c := start + v.columnOnRow(line, sub, toCells)
		all = append(all, span{a, c})
		if row == toRow {
			break
		}
	}
	primary := len(all) - 1
	slices.SortStableFunc(all, func(a, b span) int { return a.lo() - b.lo() })
	if step < 0 {
		primary = 0
	}
	v.setSpans(all, primary)
	v.lastKind = editOther
	v.moved()
}

// rowAt is the row under y.
func (v *View) rowAt(y float32) int {
	row := int((y - v.area.Y + v.scroll) / max(v.lineH, 1))
	return min(max(row, 0), v.rowCount()-1)
}

// AddNextOccurrence selects the next occurrence of the primary selection's text as another
// selection, which becomes primary; with nothing selected it selects the word at the caret.
// The search goes on from the start of the text after its end.
func (v *View) AddNextOccurrence() bool {
	start, end := v.Selection()
	if start == end {
		from, to := v.wordAt(v.caret)
		if from == to {
			return false
		}
		v.anchor, v.caret = from, to
		v.moved()
		return true
	}
	needle := v.text.AppendRange(nil, start, end)
	all, _ := v.spans()
	last := all[len(all)-1].hi()
	at := v.findFrom(needle, last, all)
	if at < 0 {
		return false
	}
	all = append(all, span{at, at + len(needle)})
	slices.SortStableFunc(all, func(a, b span) int { return a.lo() - b.lo() })
	v.setSpans(all, slices.Index(all, span{at, at + len(needle)}))
	v.moved()
	return true
}

// SelectAllOccurrences selects every occurrence of the primary selection's text (of the word at
// the caret, when nothing is selected).
func (v *View) SelectAllOccurrences() bool {
	start, end := v.Selection()
	if start == end {
		start, end = v.wordAt(v.caret)
		if start == end {
			return false
		}
	}
	needle := v.text.AppendRange(nil, start, end)
	data := v.text.Bytes()
	var all []span
	primary := 0
	for at := 0; at <= len(data)-len(needle); {
		i := strings.Index(string(data[at:]), string(needle))
		if i < 0 {
			break
		}
		if at+i == start {
			primary = len(all)
		}
		all = append(all, span{at + i, at + i + len(needle)})
		at += i + max(len(needle), 1)
	}
	if len(all) == 0 {
		return false
	}
	v.setSpans(all, primary)
	v.moved()
	return true
}

// UnselectOccurrence takes back the selection Add Selection for Next Occurrence added last
// (the primary one); the one before it becomes primary.
func (v *View) UnselectOccurrence() bool {
	if len(v.extra) == 0 {
		return false
	}
	all, primary := v.spans()
	all = slices.Delete(all, primary, primary+1)
	v.setSpans(all, max(primary-1, 0))
	v.moved()
	return true
}

// findFrom is the offset of the first occurrence of needle at or after from that is not inside
// one of taken, going on from the start of the text; -1 when there is none.
func (v *View) findFrom(needle []byte, from int, taken []span) int {
	data := string(v.text.Bytes())
	text := string(needle)
	free := func(at int) bool {
		for _, s := range taken {
			if at < s.hi() && at+len(text) > s.lo() {
				return false
			}
		}
		return true
	}
	for _, base := range []int{from, 0} {
		for at := base; at <= len(data); {
			i := strings.Index(data[at:], text)
			if i < 0 {
				break
			}
			if free(at + i) {
				return at + i
			}
			at += i + 1
		}
	}
	return -1
}

// CloneCaretAbove adds a caret on the line above the primary one, in its column, and makes it the primary.
func (v *View) CloneCaretAbove() bool { return v.cloneCaret(-1) }

// CloneCaretBelow adds a caret on the line below the primary one, in its column, and makes it the primary.
func (v *View) CloneCaretBelow() bool { return v.cloneCaret(1) }

// cloneCaret adds a caret at the primary's column on the line dir lines away, when there is one.
func (v *View) cloneCaret(dir int) bool {
	target := v.text.LineOf(v.caret) + dir
	if target < 0 || target >= v.text.LineCount() {
		return false
	}
	at := v.offsetAtCell(target, v.cellOf(v.caret))
	all, _ := v.spans()
	all = append(all, span{at, at})
	slices.SortStableFunc(all, func(a, b span) int { return a.lo() - b.lo() })
	v.setSpans(all, slices.Index(all, span{at, at}))
	v.moved()
	return true
}

// paintExtraCarets draws the extra selections' carets; their selections are drawn with the
// primary's (see Paint).
func (v *View) paintExtraCarets(canvas *gfx.Canvas, look Look) {
	primary := v.caret
	for _, s := range v.extra {
		v.caret = s.caret
		x, y := v.caretPoint()
		canvas.Fill(gfx.Rect{X: float32(int(x + 0.5)), Y: y, Width: 2, Height: v.lineH}, look.Caret)
	}
	v.caret = primary
}

// extraSelectionCells is the cells of line l the extra selections cover, as ranges.
func (v *View) extraSelectionCells(l lineRef, out [][2]int) [][2]int {
	out = out[:0]
	for _, s := range v.extra {
		if from, to := v.selectionCells(l, s.lo(), s.hi()); to > from {
			out = append(out, [2]int{from, to})
		}
	}
	return out
}
