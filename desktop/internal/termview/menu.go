package termview

import "github.com/1lck/Lithe-IDEA/desktop/internal/term"

// HasSelection reports that some text of the terminal is selected.
func (v *View) HasSelection() bool { return v.selection.selected }

// SelectionText is the selected text, or empty when nothing is selected.
func (v *View) SelectionText() string {
	if !v.selection.selected {
		return ""
	}
	return v.selection.text(v.screen)
}

// PasteClipboard sends the system clipboard to the shell as a paste, as the paste chord does.
func (v *View) PasteClipboard() { v.paste() }

// SelectAll selects every line the terminal keeps, the history and the screen.
func (v *View) SelectAll() {
	cols, rows := v.screen.Size()
	v.selection.clear()
	v.selection.anchor = v.screen.BufferPoint(term.BufferPosition{})
	v.selection.focus = v.screen.BufferPoint(term.BufferPosition{Line: v.screen.Scrollback() + rows - 1, Column: max(cols-1, 0)})
	v.selection.selected = true
}

// Clear empties the history and the screen. The line the cursor is on stays, so a shell's
// prompt and what was typed on it survive; a full-screen program keeps its screen.
func (v *View) Clear() {
	v.selection.clear()
	v.screen.ClearScrollback()
	v.screen.ClearScreen()
}

// Ended reports that the shell ended and Restart can start a new one.
func (v *View) Ended() bool { return v.ended && !v.closed && v.cfg.Exited == nil }

// Restart starts a new shell in a view whose shell ended, and reports whether it did.
func (v *View) Restart() bool { return v.restart() }
