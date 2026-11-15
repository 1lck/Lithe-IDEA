package editorview

import (
	"unicode/utf8"
)

// lineEditLimit bounds the text one line operation hands to Core: a window of the lines the
// operation can touch. A document whose selected lines are larger than this (a minified file
// of one huge line) is left alone instead of copied whole.
const lineEditLimit = 1 << 20

// LineEditInput is the part of the document a Core line operation needs: the selected lines
// and the line before and after them, so a move or a copy has the neighbor it swaps with.
// Selection offsets are UTF-16 units into Source, as Core expects. Every line operation
// works on whole lines, so the answer for the window is the answer for the document.
type LineEditInput struct {
	Source          string
	SelectionStart  int
	SelectionLength int

	base     int // byte offset of Source in the document
	revision int // document revision the window was taken at
	backward bool
}

// LineEditInput takes the window for a line operation. The second result is false when the
// view is read-only, composing, or the window is too large.
func (v *View) LineEditInput() (LineEditInput, bool) {
	if v.readOnly || v.preedit.Composing {
		return LineEditInput{}, false
	}
	start, end := v.Selection()
	first, last := v.text.LineOf(start), v.text.LineOf(end)
	first, last = max(first-1, 0), min(last+1, v.text.LineCount()-1)
	from, to := v.text.LineStart(first), v.text.LineEnd(last)
	if to-from > lineEditLimit {
		return LineEditInput{}, false
	}
	source, _ := v.text.Substring(from, to)
	return LineEditInput{
		Source:          source,
		SelectionStart:  v.utf16Units(from, start),
		SelectionLength: v.utf16Units(start, end),
		base:            from,
		revision:        v.revision,
		backward:        v.anchor > v.caret,
	}, true
}

// ApplyLineEdit puts Core's answer into the document as one undoable edit and selects what
// Core says. The text replaces [replacedStart, replacedStart+replacedLength) of the input's
// Source, in UTF-16 units. It reports false, changing nothing, when the document changed since
// the window was taken or the answer does not fit it.
func (v *View) ApplyLineEdit(in LineEditInput, replacedStart, replacedLength int, text string, selectionStart, selectionLength int) bool {
	if v.readOnly || v.preedit.Composing || v.revision != in.revision {
		return false
	}
	from, ok := utf16ToByte(in.Source, replacedStart)
	if !ok {
		return false
	}
	to, ok := utf16ToByte(in.Source, replacedStart+replacedLength)
	if !ok || to < from {
		return false
	}
	result := in.Source[:from] + text + in.Source[to:]
	selFrom, ok := utf16ToByte(result, selectionStart)
	if !ok {
		return false
	}
	selTo, ok := utf16ToByte(result, selectionStart+selectionLength)
	if !ok {
		return false
	}
	v.edit(in.base+from, in.base+to, text, editOther)
	anchor, active := in.base+selFrom, in.base+selTo
	if in.backward {
		anchor, active = active, anchor
	}
	return v.SetSelection(anchor, active)
}

// utf16ToByte is the byte offset of the UTF-16 offset units into s. It fails for an offset
// past the end or inside a surrogate pair.
func utf16ToByte(s string, units int) (int, bool) {
	if units < 0 {
		return 0, false
	}
	offset := 0
	for units > 0 {
		if offset >= len(s) {
			return 0, false
		}
		r, size := utf8.DecodeRuneInString(s[offset:])
		n := 1
		if r > 0xffff {
			n = 2
		}
		if n > units {
			return 0, false
		}
		units -= n
		offset += size
	}
	return offset, true
}
