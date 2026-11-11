package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// autoSaveCard declares the auto-save switch of the Editor page: changed files are saved a
// moment after typing stops, on by default. The switch hands its change to the settings
// owner at once.
func (w *window) autoSaveCard(c ui.C) {
	language := w.marketLanguage()
	title := i18n.Shared(language, "settings.editor.autoSave")
	on := !w.sess.values.DisableAutoSave
	w.card(c, title, i18n.Shared(language, "settings.editor.autoSaveDescription"), func() {
		if ui.Switch(c.Part("autosave"), &on, i18n.Shared(language, "settings.mac.autoSave")).Changed() {
			if w.sess.finished.Load() || w.sess.values.DisableAutoSave == !on {
				return
			}
			w.sess.values.DisableAutoSave = !on
			if w.ctrl.opts.SetDisableAutoSave != nil {
				w.ctrl.opts.SetDisableAutoSave(!on)
			}
		}
	})
}
