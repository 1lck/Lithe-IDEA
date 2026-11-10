package editorview

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"strings"
	"unicode/utf8"

	"github.com/vivaui/viva/gfx"
)

// PositionAt is the zero-based line and UTF-16 column of the character edge
// nearest the window point (x, y). The second result is false before the view
// has painted, when it has no geometry to map the point through.
func (v *View) PositionAt(x, y float32) (line, column int, ok bool) {
	if !v.painted {
		return 0, 0, false
	}
	offset := v.offsetAt(x, y)
	line = v.text.LineOf(offset)
	return line, v.utf16Units(v.text.LineStart(line), offset), true
}

// CaretRect is the caret's cell in window coordinates, for placing a popup next
// to it. The second result is false before the view has painted.
func (v *View) CaretRect() (gfx.Rect, bool) {
	if !v.painted || v.cellW <= 0 || v.lineH <= 0 {
		return gfx.Rect{}, false
	}
	x, y := v.caretPoint()
	return gfx.Rect{X: x, Y: y, Width: v.cellW, Height: v.lineH}, true
}

// ByteOffset resolves a zero-based LSP line and UTF-16 column against the live
// text. A column past the line clamps to its end and a column inside a surrogate
// pair snaps to the start of that rune, which is the position LSP itself names.
func (v *View) ByteOffset(line, utf16Column int) (int, bool) {
	if line < 0 || line >= v.text.LineCount() {
		return 0, false
	}
	start, end := v.text.LineStart(line), v.text.LineEnd(line)
	offset := start
	remaining := max(utf16Column, 0)
	v.text.Chunks(start, end, func(chunk string) bool {
		for len(chunk) > 0 && remaining > 0 {
			r, size := utf8.DecodeRuneInString(chunk)
			units := 1
			if r > 0xffff {
				units = 2
			}
			if units > remaining {
				return false
			}
			remaining -= units
			offset += size
			chunk = chunk[size:]
		}
		return remaining > 0
	})
	return offset, true
}

// SelectionUTF16 is the selection as zero-based start and end positions with UTF-16
// columns. The second result is false when nothing is selected.
func (v *View) SelectionUTF16() (startLine, startColumn, endLine, endColumn int, ok bool) {
	start, end := v.Selection()
	if start == end {
		return 0, 0, 0, 0, false
	}
	startLine = v.text.LineOf(start)
	endLine = v.text.LineOf(end)
	startColumn = v.utf16Units(v.text.LineStart(startLine), start)
	endColumn = v.utf16Units(v.text.LineStart(endLine), end)
	return startLine, startColumn, endLine, endColumn, true
}

// IndentSettings is the indentation the editor inserts for Tab: the indent unit detected
// from the document (a tab, or four spaces when spaces lead or nothing indents). A
// tab-indented document reports the editor's tab stop width as the tab size.
func (v *View) IndentSettings() (size int, insertSpaces bool) {
	switch v.indentUnit {
	case "\t":
		return tabSize, false
	case "":
		return tabSize, true
	}
	return len(v.indentUnit), true
}

// TextSnapshot returns immutable text without copying the document on the UI thread.
func (v *View) TextSnapshot() rope.Rope { return v.text }

// TextChange is a native editor replacement prepared off the window thread.
// Core has already validated the semantic edit; this only avoids replacing
// unchanged text when applying its result to the view.
type TextChange struct {
	start, end int
	text       string
	caret      int
}

// PrepareTextChange finds the changed span with the editor's existing rope diff.
// It may scan the document and must run away from the window thread.
func PrepareTextChange(before rope.Rope, text string, caret int) TextChange {
	after := rope.FromString(text)
	start, end, afterEnd := rope.Diff(before, after)
	return TextChange{start: start, end: end, text: strings.Clone(text[start:afterEnd]), caret: caret}
}

// ApplyTextChange applies a prepared replacement as one undoable edit. The
// caller verifies the document revision still matches the snapshot.
func (v *View) ApplyTextChange(change TextChange) bool {
	if v.preedit.Composing {
		return false
	}
	v.edit(change.start, change.end, change.text, editOther)
	offset := min(max(change.caret, 0), v.text.Len())
	for offset > 0 && offset < v.text.Len() && !utf8.RuneStart(v.text.ByteAt(offset)) {
		offset--
	}
	v.anchor, v.caret = offset, offset
	v.lastKind = editOther
	v.moved()
	return true
}
