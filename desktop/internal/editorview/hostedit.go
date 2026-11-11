package editorview

import (
	"errors"
	"slices"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// What a plugin backend may do to a document through the host: read positions in
// the contract's terms (UTF-16 columns) and change the text as one undoable step.
// The checks that need Core's rules (permissions, versions, limits) live with the
// caller; this file only keeps the view's own invariants.

var (
	// ErrPosition reports a position that is outside the text or splits a
	// surrogate pair.
	ErrPosition = errors.New("editorview: position is outside the text")
	// ErrOverlap reports edits whose ranges overlap or are out of order.
	ErrOverlap = errors.New("editorview: edits overlap")
	// ErrReadOnly reports a view that does not take changes.
	ErrReadOnly = errors.New("editorview: the document is read-only")
	// ErrComposing reports an active input-method composition, which an outside
	// change would corrupt.
	ErrComposing = errors.New("editorview: input method composition is active")
)

// Range is a half-open span of byte offsets of the current text.
type Range struct{ Start, End int }

// TextEdit replaces a byte range with Text.
type TextEdit struct {
	Range
	Text string
}

// SetReadOnly makes the view refuse every change. Undo history of a read-only
// view stays empty, so nothing can bring text back in.
func (v *View) SetReadOnly(on bool) { v.readOnly = on }

// ReadOnly reports whether the view refuses changes.
func (v *View) ReadOnly() bool { return v.readOnly }

// LineEnding is "crlf" when the first line break is \r\n and "lf" otherwise.
func (v *View) LineEnding() string {
	if v.text.LineCount() > 1 {
		if end := v.text.LineEnd(0); end > 0 && v.text.ByteAt(end-1) == '\r' {
			return "crlf"
		}
	}
	return "lf"
}

// lineContentEnd is where the characters of a line end: before its "\r\n".
func (v *View) lineContentEnd(line int) int {
	end := v.text.LineEnd(line)
	if end > v.text.LineStart(line) && end < v.text.Len() && v.text.ByteAt(end-1) == '\r' {
		end--
	}
	return end
}

// OffsetOf resolves a zero-based line and UTF-16 column to a byte offset. Unlike
// ByteOffset, a column past the line or inside a surrogate pair is an error, so a
// plugin's stale range is refused instead of silently moved.
func (v *View) OffsetOf(line, column int) (int, error) {
	if line < 0 || line >= v.text.LineCount() || column < 0 {
		return 0, ErrPosition
	}
	start, end := v.text.LineStart(line), v.lineContentEnd(line)
	offset, remaining := start, column
	ok := true
	v.text.Chunks(start, end, func(chunk string) bool {
		for len(chunk) > 0 && remaining > 0 {
			r, size := utf8.DecodeRuneInString(chunk)
			units := 1
			if r > 0xffff {
				units = 2
			}
			if units > remaining {
				ok = false
				return false
			}
			remaining -= units
			offset += size
			chunk = chunk[size:]
		}
		return remaining > 0
	})
	if !ok || remaining > 0 {
		return 0, ErrPosition
	}
	return offset, nil
}

// PositionOf is the zero-based line and UTF-16 column of a byte offset.
func (v *View) PositionOf(offset int) (line, column int) {
	offset = min(max(offset, 0), v.text.Len())
	return v.positionAt(offset)
}

// SelectionOffsets are the selection's anchor and active (caret) offsets.
func (v *View) SelectionOffsets() (anchor, active int) { return v.anchor, v.caret }

// SetSelection selects from anchor to active and reveals the active end on the
// next paint. Both must be offsets of the current text.
func (v *View) SetSelection(anchor, active int) bool {
	if v.preedit.Composing || anchor < 0 || active < 0 || anchor > v.text.Len() || active > v.text.Len() {
		return false
	}
	v.anchor, v.caret = anchor, active
	v.goal, v.lastKind, v.reveal = -1, editOther, true
	v.clearCursorHistory()
	v.moved()
	return true
}

// ApplyEdits applies non-overlapping edits, given in ascending order of their
// ranges, as one undo step and one change to the language-server session. The
// caret ends after the last replacement. Nothing is changed when any edit is
// refused.
func (v *View) ApplyEdits(edits []TextEdit) error {
	switch {
	case v.readOnly:
		return ErrReadOnly
	case v.preedit.Composing:
		return ErrComposing
	}
	last := 0
	for _, e := range edits {
		if e.Start < last || e.End < e.Start || e.End > v.text.Len() ||
			inside(v.text, e.Start) || inside(v.text, e.End) {
			if e.Start < last && e.Start >= 0 {
				return ErrOverlap
			}
			return ErrPosition
		}
		last = e.End
	}
	// Build the result from the back so earlier offsets stay valid, then let the
	// rope diff find the one span that changed.
	after := v.text
	caret := 0
	for _, e := range slices.Backward(edits) {
		after = after.Replace(e.Start, e.End, []byte(e.Text))
	}
	if len(edits) > 0 {
		shift := 0
		for _, e := range edits[:len(edits)-1] {
			shift += len(e.Text) - (e.End - e.Start)
		}
		tail := edits[len(edits)-1]
		caret = tail.Start + shift + len(tail.Text)
	}
	start, oldEnd, newEnd := rope.Diff(v.text, after)
	if start == oldEnd && start == newEnd {
		return nil
	}
	text, _ := after.Substring(start, newEnd)
	v.edit(start, oldEnd, text, editOther)
	v.anchor, v.caret = min(caret, v.text.Len()), min(caret, v.text.Len())
	v.moved()
	return nil
}

func inside(text rope.Rope, offset int) bool {
	return offset > 0 && offset < text.Len() && !utf8.RuneStart(text.ByteAt(offset))
}
