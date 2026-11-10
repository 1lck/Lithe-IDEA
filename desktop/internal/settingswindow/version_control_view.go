package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// versionControlPage is the Version Control page: the Git switches of the editor. Opening the
// page writes nothing; a switch hands its change to the settings owner at once.
func (w *window) versionControlPage(c ui.C) {
	language := w.marketLanguage()
	gutterTitle := i18n.Shared(language, "desktop.git.settings.gutter")
	blameTitle := i18n.Shared(language, "desktop.git.settings.blame")
	gutter := !w.sess.values.HideGitGutter
	blame := w.sess.values.InlineGitBlame
	w.pageScroll(c, pageVersionControl, func() {
		w.card(c, gutterTitle, i18n.Shared(language, "desktop.git.settings.gutterHelp"), func() {
			if ui.Switch(c.Part("gutter"), &gutter, gutterTitle).Changed() {
				w.setHideGitGutter(!gutter, false)
			}
		})
		w.card(c, blameTitle, i18n.Shared(language, "desktop.git.settings.blameHelp"), func() {
			if ui.Switch(c.Part("blame"), &blame, blameTitle).Changed() {
				w.setInlineGitBlame(blame, false)
			}
		})
	})
}
