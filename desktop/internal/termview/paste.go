package termview

import "github.com/1lck/Lithe-IDEA/desktop/internal/term"

// Paste sends text to the live shell as a paste, the way the clipboard is pasted:
// bracketed when the program asked for bracketed paste, so a shell inserts it at the
// prompt without running it. It reports whether the shell took it.
func (v *View) Paste(text string) bool {
	if v.shell == nil || text == "" {
		return false
	}
	return v.sendInput(term.EncodePaste(text, v.screen.Modes().BracketedPaste))
}
