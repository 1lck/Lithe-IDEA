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

// vimStatusShown says a status bar item shows: the Vim item only while the Vim keys are on.
func (a *App) vimStatusShown(i int) bool {
	return a.chrome.catalog[i].id != itemVim || a.settings.VimMode
}

// vimStatusText is the status bar's reading of the Vim mode: the mode of the editor that has the
// keyboard or the selected one, or the item's name when no editor shows one.
func (a *App) vimStatusText() string {
	if p := a.project; p != nil {
		if d := p.selectedDocument(p.docs.group); d != nil {
			if text := d.view.VimStatus(); text != "" {
				return text
			}
		}
	}
	return a.text.Status.Vim
}

// vimExit runs the Vim commands that save and close document d: w saves, q closes, q! closes
// without saving, and wq and x save and close. It reports false for any other command.
func (a *App) vimExit(p *project, d *document, cmd string) bool {
	switch cmd {
	case "w":
		a.saveDocument(p, d.id)
	case "q":
		a.closeDocument(p, d.id)
	case "q!":
		a.removeDocument(p, d)
	case "wq", "x":
		a.saveDocument(p, d.id)
		a.closeDocument(p, d.id)
	default:
		return false
	}
	return true
}
