package editorview

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// PreparedEdit is an immutable native text replacement laid out on a worker.
// Core has already planned the edit; this only prepares the native rope and reporting span.
type PreparedEdit struct {
	before, after, saved rope.Rope
	dirty                bool
	change               Edit
	caret, widest        int
}

// PrepareEdits must run off the UI thread. A bulk replacement builds its rope and
// measures width here, so applying the result does not rebuild a document in Paint.
func PrepareEdits(before, saved rope.Rope, edits []TextEdit) (PreparedEdit, error) {
	after := before
	last := 0
	for _, e := range edits {
		if e.Start < last {
			return PreparedEdit{}, ErrOverlap
		}
		if e.Start < 0 || e.End < e.Start || e.End > before.Len() || inside(before, e.Start) || inside(before, e.End) {
			return PreparedEdit{}, ErrPosition
		}
		last = e.End
	}
	for i := len(edits) - 1; i >= 0; i-- {
		e := edits[i]
		after = after.Replace(e.Start, e.End, []byte(e.Text))
	}
	prepared := PreparedEdit{before: before, after: after, saved: saved, dirty: !after.Equal(saved)}
	if len(edits) == 0 {
		return prepared, nil
	}
	start, end, newEnd := rope.Diff(before, after)
	if start == end && start == newEnd {
		prepared.after = before
		return prepared, nil
	}
	prepared.widest = widestLine(after, 0, after.LineCount()-1)
	text, _ := after.Substring(start, newEnd)
	prepared.change.Text = strings.Clone(text)
	prepared.change.StartLine, prepared.change.StartColumn = SnapshotUTF16(before, start)
	prepared.change.EndLine, prepared.change.EndColumn = SnapshotUTF16(before, end)
	tail := edits[len(edits)-1]
	prepared.caret = tail.Start + len(tail.Text)
	for _, e := range edits[:len(edits)-1] {
		prepared.caret += len(e.Text) - (e.End - e.Start)
	}
	return prepared, nil
}

// ApplyPreparedEdit keeps saved contents and undo history while replacing the native
// buffer. A stale result, composing input or a read-only view changes nothing.
func (v *View) ApplyPreparedEdit(prepared PreparedEdit) bool {
	if v.readOnly || v.preedit.Composing || !v.text.Same(prepared.before) || !v.saved.Same(prepared.saved) {
		return false
	}
	if v.text.Same(prepared.after) {
		return true
	}
	v.undo = append(v.undo, v.snapshot())
	if len(v.undo) > undoLimit {
		v.undo = v.undo[len(v.undo)-undoLimit:]
	}
	v.redo = v.redo[:0]
	v.extra = nil
	v.text = prepared.after
	v.widest = prepared.widest
	v.revision++
	v.clearCursorHistory()
	v.hl.SetText(v.text)
	v.forgetRows()
	v.anchor, v.caret = prepared.caret, prepared.caret
	v.lastKind, v.goal = editOther, -1
	v.dirty = prepared.dirty
	v.moved()
	v.reportEdit(prepared.change)
	return true
}

// SnapshotUTF16 computes the native line and UTF-16 column of a byte offset. Call on a
// worker for unbounded source lines; capturing the offset and immutable rope is O(1).
func SnapshotUTF16(snapshot rope.Rope, at int) (line, column int) {
	at = min(max(at, 0), snapshot.Len())
	line = snapshot.LineOf(at)
	snapshot.Chunks(snapshot.LineStart(line), at, func(chunk string) bool {
		for _, r := range chunk {
			column++
			if r > 0xffff {
				column++
			}
		}
		return true
	})
	return
}
