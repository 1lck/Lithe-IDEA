package editorview

import (
	"strings"
)

// Vim Visual Block (Control+V): a rectangle of columns over the lines from the block's first line to
// its last. The rectangle is kept as cells, so it stays where the cells are on lines of other lengths.
// Each line of it is one selection of the multi-caret set (multicaret.go), so the commands that act at
// every caret act on the whole block: d, x, y, c, r and typing in Insert mode after I, A or c. The
// block's two corners are the state; the selections are derived from them after every key.

// vimCtrlV is the text of Control+V, which starts the block and ends it.
const vimCtrlV = "\x16"

// vimBlockCorners is the rectangle of the block: the line and cell of its anchor corner and of its caret
// corner, and whether $ extends every line to its end.
type vimBlockCorners struct {
	anchorLine, anchorCell int
	caretLine, caretCell   int
	toEnd                  bool
	// end is the offset the primary selection ends at, as the last sync left it. The caret is moved from
	// there by a motion, so a change of the caret from end means a motion moved the block's corner.
	end int
}

// cellOf is the display column of offset within its line, in cells.
func (v *View) cellOf(offset int) int {
	line := v.text.LineOf(offset)
	l := v.ref(line)
	return v.cellsAt(l, offset-l.start)
}

// offsetAtCell is the offset on line of the column cells, clamped to the line's end.
func (v *View) offsetAtCell(line, cells int) int {
	l := v.ref(line)
	end := v.lineEnd(line)
	at := l.start + v.columnFrom(l, 0, l.size, 0, float32(cells))
	return min(at, end)
}

// vimBlockStart turns Visual Block on, with the caret as both corners.
func (v *View) vimBlockStart() {
	st := &v.vim
	line := v.text.LineOf(v.caret)
	cell := v.cellOf(v.caret)
	st.block = vimBlockCorners{anchorLine: line, anchorCell: cell, caretLine: line, caretCell: cell}
	st.mode = vimVisualBlock
	v.vimBlockSync()
}

// blockSpans is the selection of every line of the block, in line order, and the index of the caret's line.
// Each selection is exclusive: a line shorter than the block gives an empty one at its end.
func (v *View) blockSpans() ([]span, int) {
	b := &v.vim.block
	lo, hi := min(b.anchorLine, b.caretLine), max(b.anchorLine, b.caretLine)
	left, right := min(b.anchorCell, b.caretCell), max(b.anchorCell, b.caretCell)
	spans := make([]span, 0, hi-lo+1)
	primary := 0
	for line := lo; line <= hi; line++ {
		from := v.offsetAtCell(line, left)
		to := v.offsetAtCell(line, right+1)
		if b.toEnd {
			to = v.lineEnd(line)
		}
		spans = append(spans, span{from, max(to, from)})
		if line == b.caretLine {
			primary = len(spans) - 1
		}
	}
	return spans, primary
}

// vimBlockSync derives the block's selections from its corners after a key. The caret moved by a motion
// changes the caret corner; the primary selection is the caret's line, set as the view's own selection.
func (v *View) vimBlockSync() {
	b := &v.vim.block
	if v.caret != b.end {
		b.caretLine = v.text.LineOf(v.caret)
		b.caretCell = v.cellOf(v.caret)
	}
	spans, primary := v.blockSpans()
	v.setSpans(spans, primary)
	b.end = v.caret
}

// vimBlockExit goes back to Normal mode with one caret: on the block's caret corner, or on its top-left
// corner when topLeft says so (after an operator, as Vim does).
func (v *View) vimBlockExit(topLeft ...bool) {
	st := &v.vim
	b := st.block
	v.ClearExtraCarets()
	at := v.offsetAtCell(b.caretLine, b.caretCell)
	if len(topLeft) > 0 && topLeft[0] {
		at = v.offsetAtCell(min(b.anchorLine, b.caretLine), min(b.anchorCell, b.caretCell))
	}
	v.anchor, v.caret = at, at
	st.mode = vimNormal
	st.block = vimBlockCorners{}
	v.vimClamp()
	v.moved()
}

// vimBlockEach runs fn once for every line of the block, from the last line to the first, as one undo
// step. fn edits the line's selection and returns the offset the selection collapses to.
func (v *View) vimBlockEach(fn func(from, to int) int) {
	spans, primary := v.blockSpans()
	v.setSpans(spans, primary)
	v.eachCaret(func() bool {
		from, to := v.Selection()
		at := fn(from, to)
		v.anchor, v.caret = at, at
		return true
	})
}

// vimBlockOp deletes (d), yanks (y) or changes (c) the block. A change leaves one caret on each line, in
// Insert mode, so what is typed goes to every line.
func (v *View) vimBlockOp(op byte) {
	st := &v.vim
	var texts []string
	v.vimBlockEach(func(from, to int) int {
		texts = append(texts, string(v.text.AppendRange(nil, from, to)))
		if op != 'y' {
			v.edit(from, to, "", editOther)
		}
		return from
	})
	// The lines were visited from the last to the first.
	for i, j := 0, len(texts)-1; i < j; i, j = i+1, j-1 {
		texts[i], texts[j] = texts[j], texts[i]
	}
	st.reg, st.regLine = strings.Join(texts, "\n"), false
	if op == 'y' {
		v.vimBlockExit(true)
		return
	}
	if op == 'c' {
		v.vimBlockInsertMode()
		return
	}
	v.vim.changed = true
	v.vimBlockExit(true)
}

// vimBlockInsertMode starts Insert mode with the block's carets, one on each line, kept until Escape.
func (v *View) vimBlockInsertMode() {
	st := &v.vim
	st.mode = vimInsert
	st.blockInsert = true
	st.changed = true
	st.insertCount, st.insertStart = 1, v.caret
	st.block = vimBlockCorners{}
}

// vimBlockInsert is I (at the block's left column) and A (after its right column). A pads a line that ends
// before the column with spaces. I skips the lines that end before the column, as Vim does.
func (v *View) vimBlockInsert(after bool) {
	st := &v.vim
	b := st.block
	lo, hi := min(b.anchorLine, b.caretLine), max(b.anchorLine, b.caretLine)
	left, right := min(b.anchorCell, b.caretCell), max(b.anchorCell, b.caretCell)
	column := left
	if after {
		column = right + 1
	}
	if after && !b.toEnd {
		// Pad from the last line up, so the offsets of the lines before stay true.
		for line := hi; line >= lo; line-- {
			if width := v.cellOf(v.lineEnd(line)); width < column {
				v.edit(v.lineEnd(line), v.lineEnd(line), strings.Repeat(" ", column-width), editOther)
			}
		}
	}
	var offsets []int
	primary := -1
	for line := lo; line <= hi; line++ {
		end := v.lineEnd(line)
		if !after && !b.toEnd && v.cellOf(end) < column {
			continue
		}
		at := v.offsetAtCell(line, column)
		if b.toEnd && after {
			at = end
		}
		offsets = append(offsets, at)
		if line == b.caretLine {
			primary = len(offsets) - 1
		}
	}
	if len(offsets) == 0 {
		v.vimBlockExit()
		return
	}
	if primary < 0 {
		primary = len(offsets) - 1
	}
	spans := make([]span, len(offsets))
	for i, at := range offsets {
		spans[i] = span{at, at}
	}
	v.setSpans(spans, primary)
	v.vimBlockInsertMode()
}

// vimBlockPaste replaces every line of the block with the register. A register of one line per block line
// (a block yank, or lines of the same count) gives each line its own text; any other text goes to every line.
func (v *View) vimBlockPaste() {
	st := &v.vim
	text, _ := v.vimReadReg(st.regName)
	st.regName = 0
	if text == "" {
		v.vimBlockExit(true)
		return
	}
	parts := strings.Split(text, "\n")
	n, _ := v.blockSpans()
	if len(parts) != len(n) {
		parts = []string{text}
	}
	st.changed = true
	visited := 0
	v.vimBlockEach(func(from, to int) int {
		piece := parts[0]
		if len(parts) == len(n) {
			// The lines are visited from the last to the first.
			piece = parts[len(n)-1-visited]
		}
		visited++
		v.edit(from, to, piece, editOther)
		return from + len(piece)
	})
	v.vimBlockExit(true)
}

// vimBlockReplace replaces every character of the block with ch.
func (v *View) vimBlockReplace(ch string) {
	v.vim.changed = true
	v.vimBlockEach(func(from, to int) int {
		n := len([]rune(string(v.text.AppendRange(nil, from, to))))
		if n == 0 {
			return from
		}
		v.edit(from, to, strings.Repeat(ch, n), editOther)
		return from
	})
	v.vimBlockExit(true)
}

// vimBlockCommand runs a command key that Visual Block takes for itself, and reports whether it did. The
// motions are left to the Visual commands, which move the caret the block follows.
func (v *View) vimBlockCommand(s string) bool {
	st := &v.vim
	b := &st.block
	switch s {
	case vimEscape:
		v.vimBlockExit()
	case "r":
		st.pend = 'r'
		return true
	case "d", "x":
		v.vimBlockOp('d')
	case "D", "X":
		b.toEnd = true
		v.vimBlockOp('d')
	case "y", "Y":
		v.vimBlockOp('y')
	case "c", "s":
		v.vimBlockOp('c')
	case "C", "S":
		b.toEnd = true
		v.vimBlockOp('c')
	case "p", "P":
		v.vimBlockPaste()
	case "I":
		v.vimBlockInsert(false)
	case "A":
		v.vimBlockInsert(true)
	case "o":
		b.anchorLine, b.caretLine = b.caretLine, b.anchorLine
		b.anchorCell, b.caretCell = b.caretCell, b.anchorCell
	case "O":
		b.anchorCell, b.caretCell = b.caretCell, b.anchorCell
	case "v", "V":
		anchor := v.offsetAtCell(b.anchorLine, b.anchorCell)
		caret := v.offsetAtCell(b.caretLine, b.caretCell)
		st.block = vimBlockCorners{}
		v.ClearExtraCarets()
		v.anchor, v.caret = anchor, caret
		st.mode = vimVisual
		if s == "V" {
			st.mode = vimVisualLine
		}
		return true
	case "$":
		b.toEnd = true
		return false
	case "0", "^", "h", "l", "w", "W", "b", "B", "e", "E", "f", "F", "t", "T":
		b.toEnd = false
		return false
	default:
		return false
	}
	v.vimCancel()
	return true
}

// vimBlockKeepsCarets says the carets of the block stay through the keys: in the block itself, and in
// Insert mode after I, A or c.
func (v *View) vimBlockKeepsCarets() bool {
	return v.vim.mode == vimVisualBlock || v.vim.blockInsert
}
