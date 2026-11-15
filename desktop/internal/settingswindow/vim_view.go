package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// vimCard declares the Vim switch of the Editor page: the editor's Vim keys, off by default. The
// switch hands its change to the settings owner at once.
func (w *window) vimCard(c ui.C) {
	language := w.marketLanguage()
	title := i18n.Shared(language, "desktop.editor.vimMode")
	vim := w.sess.values.VimMode
	w.card(c, title, i18n.Shared(language, "desktop.editor.vimModeHelp"), func() {
		if ui.Switch(c.Part("vim"), &vim, title).Changed() {
			w.setVimMode(vim, false)
		}
	})
}

// setVimMode stores the Vim switch and hands it to the settings owner at once.
func (w *window) setVimMode(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.VimMode == value) {
		return
	}
	w.sess.values.VimMode = value
	if w.ctrl.opts.SetVimMode != nil {
		w.ctrl.opts.SetVimMode(value)
	}
}
