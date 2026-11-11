package editorview

import "unicode/utf8"

// This file applies edits that another view made (matrix id git-diff-review): the Diff tab
// mirrors its editable side into the document it edits, and the document's changes into the
// side. The positions are the ones an Edit carries, so the two views need not share a rope.

// ApplyEdit replaces the text of edit in v, the way edit's view reported it: zero-based LSP lines
// and UTF-16 columns, and the text that goes in. It reports false, and changes nothing, when the
// positions are not in v's text or v is read only.
//
// With recordUndo the change is one undo step of v, and v's redo history is cleared. Without it the
// change leaves v's undo history alone: the view that made the change keeps the undo for it. Either
// way v reports the change to its OnEdit, so a caller that mirrors edits must not mirror that report
// back to the view it came from.
func (v *View) ApplyEdit(edit Edit, recordUndo bool) bool {
	if v.readOnly {
		return false
	}
	start, ok := v.offsetOf(edit.StartLine, edit.StartColumn)
	if !ok {
		return false
	}
	end, ok := v.offsetOf(edit.EndLine, edit.EndColumn)
	if !ok || end < start {
		return false
	}
	// The other view's edit does not move this view's selection to the edit: each end keeps its place
	// in the text around the change.
	anchor, caret := v.anchor, v.caret
	v.remoteNoUndo = !recordUndo
	v.edit(start, end, edit.Text, editOther)
	v.remoteNoUndo = false
	delta := len(edit.Text) - (end - start)
	v.anchor = shiftForEdit(anchor, start, end, delta)
	v.caret = shiftForEdit(caret, start, end, delta)
	return true
}

// shiftForEdit is where offset at lies after the bytes start..end were replaced, which changed the
// text by delta bytes. An offset past the replaced bytes moves with them; one inside them goes to
// their start.
func shiftForEdit(at, start, end, delta int) int {
	switch {
	case at > end || at == end && start < end:
		return at + delta
	case at > start:
		return start
	}
	return at
}

// offsetOf is the byte offset of the zero-based line and UTF-16 column in v's text. It reports
// false when the line or the column is past the text.
func (v *View) offsetOf(line, column int) (int, bool) {
	if line < 0 || line >= v.text.LineCount() || column < 0 {
		return 0, false
	}
	start, end := v.text.LineStart(line), v.text.LineEnd(line)
	bytes := v.text.AppendRange(nil, start, end)
	units, i := 0, 0
	for i < len(bytes) && units < column {
		r, size := utf8.DecodeRune(bytes[i:])
		if r >= 0x10000 {
			units += 2
		} else {
			units++
		}
		i += size
	}
	if units < column {
		return 0, false
	}
	return start + i, true
}

// CopyContent is the text of v as Content, so that another view shows the same text. The rope is
// shared, not copied.
func (v *View) CopyContent() Content {
	return Content{text: v.text, indent: indentUnit(v.text), widest: widestLine(v.text, 0, v.text.LineCount()-1)}
}

// LineRowAt is LineAt with the place of y inside the line's row: fraction is 0 at the top edge of
// the row and reaches 1 at its bottom edge, so a caller can split a row into bands, such as the
// row of a fold's placeholder.
func (v *View) LineRowAt(y float32) (line int, fraction float32, ok bool) {
	if !v.painted || v.lineH <= 0 {
		return 0, 0, false
	}
	at := y - v.area.Y + v.scroll
	if at < 0 {
		return 0, 0, false
	}
	row := int(at / v.lineH)
	if row >= v.rowCount() {
		return 0, 0, false
	}
	line, _ = v.rowLine(row)
	return line, (at - float32(row)*v.lineH) / v.lineH, true
}
