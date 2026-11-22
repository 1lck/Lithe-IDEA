package termview

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
)

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
//
// PowerShell's line editor (PSReadLine) remembers the screen row it writes on, so after
// the clear it would go on writing at the old row, below blank rows. The form feed it
// reads as Ctrl+L makes it redraw at the top; see lineEditorNeedsFormFeed for when it is
// sent.
func (v *View) Clear() {
	v.selection.clear()
	v.screen.ClearScrollback()
	cleared := v.screen.ClearScreen()
	// The clear starts a new buffer generation; taking it here keeps the next output
	// from reading it as a change made under a later selection.
	v.reconcileSelection()
	if cleared && v.lineEditorNeedsFormFeed() {
		v.sendInput([]byte{'\f'})
	}
}

// lineEditorNeedsFormFeed reports that a form feed reaches PowerShell's line editor rather
// than a program started from it. Only the interactive shell the shell menu starts (no
// Args of its own) runs that editor, and only while it runs no program: the shell reports
// no prompts to tell a command apart, so Busy does, and a form feed typed into a program
// would be that program's input. Nothing is sent when the clear was refused on the
// alternate screen, which a full-screen program owns.
func (v *View) lineEditorNeedsFormFeed() bool {
	return v.shell != nil && v.cfg.Args == nil && v.shell.Kind() == shellkind.PowerShell && !v.shell.Busy()
}

// Ended reports that the shell ended and Restart can start a new one.
func (v *View) Ended() bool { return v.ended && !v.closed && v.cfg.Exited == nil && !v.cfg.NoRestart }

// Restart starts a new shell in a view whose shell ended, and reports whether it did.
func (v *View) Restart() bool { return v.restart() }
