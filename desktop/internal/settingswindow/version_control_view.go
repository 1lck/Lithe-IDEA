package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// versionControlPage is the Version Control page: the Git switches of the editor. Opening the
// page writes nothing; a switch hands its change to the settings owner at once.
func (w *window) versionControlPage(c ui.C) {
	language := w.marketLanguage()
	if w.ctrl.opts.GitHub != nil {
		w.gitHubCard(c, language, w.ctrl.opts.GitHub)
	}
	gutterTitle := i18n.Shared(language, "desktop.git.settings.gutter")
	blameTitle := i18n.Shared(language, "desktop.git.settings.blame")
	gutter := !w.sess.values.HideGitGutter
	blame := w.sess.values.InlineGitBlame
	changeLists := !w.sess.values.HideChangeLists
	parents := !w.sess.values.HideParentReferences
	changeListsTitle := i18n.Shared(language, "desktop.git.settings.changeLists")
	parentsTitle := i18n.Shared(language, "desktop.git.settings.parentReferences")
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
		w.card(c, changeListsTitle, i18n.Shared(language, "desktop.git.settings.changeListsHelp"), func() {
			if ui.Switch(c.Part("changeLists"), &changeLists, changeListsTitle).Changed() {
				w.setHideChangeLists(!changeLists, false)
			}
		})
		w.card(c, parentsTitle, i18n.Shared(language, "desktop.git.settings.parentReferencesHelp"), func() {
			if ui.Switch(c.Part("parentReferences"), &parents, parentsTitle).Changed() {
				w.setHideParentReferences(!parents, false)
			}
		})
	})
}
