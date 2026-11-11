package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// vim_mode.go wires the Vim keys of the editor into the workbench: the switch the settings and the
// command catalog turn on and off, the Vim chords that the workbench must not take while an editor
// with the Vim keys has the keyboard, and the status bar item that shows the mode.

// setVimMode stores the Vim switch. Every open editor takes it on its next paint (see documentInput).
func (a *App) setVimMode(on bool) {
	if a.settings.VimMode == on {
		return
	}
	a.settings.VimMode = on
	a.saveSettings()
}

// vimOwnsChord reports whether a Control chord belongs to the Vim mode: with the Vim keys on and an
// editor focused, Ctrl+R, Ctrl+B, Ctrl+F, Ctrl+W and Ctrl+T are the editor's, not the workbench's.
func (a *App) vimOwnsChord(c ui.C, mods gfx.Modifiers, name string) bool {
	if !a.settings.VimMode || mods != gfx.ModifierControl {
		return false
	}
	if a.focusedDocument(c.Canvas().Focused()) == nil {
		return false
	}
	switch name {
	case "r", "b", "f", "w", "t":
		return true
	}
	return false
}
