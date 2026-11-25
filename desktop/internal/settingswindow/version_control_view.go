package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Version Control page is the group's own page, which its sidebar row and the breadcrumb
// above the Git page open. Like Languages & Frameworks it holds no setting: it is a directory
// of the pages under the group, one for each version control system, Git the only one so far.

// versionControlPage is the title, a line on what the page lists and the directory of the
// version control systems' pages.
func (w *window) versionControlPage(c ui.C) {
	b := &w.bp
	language := w.marketLanguage()
	ui.Scroll(c).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		ui.Column(c).FillWidth().MaxWidth(buildPageWidth).PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Children(func() {
			ui.Text(c, titleOf(&w.text.Settings, pageVersionControl)).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
			ui.Row(c).Height(4).Shrink(0)
			ui.Wrap(c, i18n.Shared(language, "desktop.versionControlSettings.intro")).FontSize(buildSmall).Color(b.sub)
			ui.Row(c).Height(12).Shrink(0)
			w.directory(c, []directoryEntry{{
				key: "git", tile: gitTile, icon: icons.GitBranch, title: titleOf(&w.text.Settings, pageGit),
				desc: i18n.Shared(language, "desktop.versionControlSettings.directoryGit"),
				open: func() { w.selectSettingsPage(pageGit, "") },
			}})
		})
	})
}

// gitPage is the Git page under Version Control: the GitHub account, then the Git switches of
// the editor, the Commit window, the Git Log's limits and the Git console. Opening the page
// writes nothing; a switch hands its change to the settings owner at once.
func (w *window) gitPage(c ui.C) {
	language := w.marketLanguage()
	gutterTitle := i18n.Shared(language, "desktop.git.settings.gutter")
	blameTitle := i18n.Shared(language, "desktop.git.settings.blame")
	gutter := !w.sess.values.HideGitGutter
	blame := w.sess.values.InlineGitBlame
	changeLists := !w.sess.values.HideChangeLists
	parents := !w.sess.values.HideParentReferences
	changeListsTitle := i18n.Shared(language, "desktop.git.settings.changeLists")
	parentsTitle := i18n.Shared(language, "desktop.git.settings.parentReferences")
	w.pageScroll(c, pageGit, func() {
		// The account card is the page's first card, inside the scroll so it lines up and scrolls
		// with the others.
		if w.ctrl.opts.GitHub != nil {
			w.gitHubCard(c, language, w.ctrl.opts.GitHub)
		}
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
		w.gitLogLimitsCard(c, language)
		w.gitConsoleCards(c, language)
	})
}
