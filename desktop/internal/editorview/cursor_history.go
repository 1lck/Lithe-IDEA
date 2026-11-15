package editorview

// Cursor history: Undo restores the selection before a keyboard move before it takes back
// text, and Ctrl+U / Ctrl+Shift+U restore and replay selections on their own. A typing edit,
// a mouse move and an API selection change clear the history, so it never replays a position
// that belongs to text or a document the user has left.

const cursorHistoryLimit = 100

// cursorSpot is one selection: the ends as offsets into the current text.
type cursorSpot struct {
	anchor, caret int
}

// rememberCursor records the selection a keyboard move left and makes Undo restore it first.
// A redo chain that was current becomes stale as soon as the user moves again.
func (v *View) rememberCursor(spot cursorSpot) {
	if len(v.cursorUndo) == 0 || v.cursorUndo[len(v.cursorUndo)-1] != spot {
		v.cursorUndo = append(v.cursorUndo, spot)
		if len(v.cursorUndo) > cursorHistoryLimit {
			v.cursorUndo = v.cursorUndo[len(v.cursorUndo)-cursorHistoryLimit:]
		}
	}
	v.cursorRedo = v.cursorRedo[:0]
	v.cursorPending = true
	v.cursorRedoPending = false
}

// clearCursorHistory forgets every remembered selection. It runs when the text changes or the
// selection moves by anything but a key, so the history is always about the text on screen.
func (v *View) clearCursorHistory() {
	v.cursorUndo = v.cursorUndo[:0]
	v.cursorRedo = v.cursorRedo[:0]
	v.cursorPending = false
	v.cursorRedoPending = false
}

// CursorUndoPending reports whether Undo would restore a selection rather than text.
func (v *View) CursorUndoPending() bool {
	return v.cursorPending && len(v.cursorUndo) > 0
}

// CursorUndo restores the selection before the most recent keyboard move. It reports whether
// a remembered selection was restored.
func (v *View) CursorUndo() bool {
	if len(v.cursorUndo) == 0 {
		return false
	}
	spot := v.cursorUndo[len(v.cursorUndo)-1]
	v.cursorUndo = v.cursorUndo[:len(v.cursorUndo)-1]
	v.cursorRedo = append(v.cursorRedo, cursorSpot{anchor: v.anchor, caret: v.caret})
	if len(v.cursorRedo) > cursorHistoryLimit {
		v.cursorRedo = v.cursorRedo[len(v.cursorRedo)-cursorHistoryLimit:]
	}
	v.anchor, v.caret = spot.anchor, spot.caret
	v.lastKind = editOther
	v.moved()
	v.cursorPending = false
	v.cursorRedoPending = true
	return true
}

// CursorRedo replays a selection CursorUndo restored, and reports whether it did.
func (v *View) CursorRedo() bool {
	if !v.cursorRedoPending || len(v.cursorRedo) == 0 {
		return false
	}
	spot := v.cursorRedo[len(v.cursorRedo)-1]
	v.cursorRedo = v.cursorRedo[:len(v.cursorRedo)-1]
	v.cursorUndo = append(v.cursorUndo, cursorSpot{anchor: v.anchor, caret: v.caret})
	if len(v.cursorUndo) > cursorHistoryLimit {
		v.cursorUndo = v.cursorUndo[len(v.cursorUndo)-cursorHistoryLimit:]
	}
	v.anchor, v.caret = spot.anchor, spot.caret
	v.lastKind = editOther
	v.moved()
	v.cursorPending = false
	v.cursorRedoPending = false
	return true
}
