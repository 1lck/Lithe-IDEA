package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file is the Git console cards of the Git settings page (matrix id git-history). The
// first card chooses which kinds of internal Git queries the console leaves out: the
// successful queries of an omitted kind are never recorded, so they take none of the journal's
// records, and omitting a kind removes those it kept. The second chooses how the console
// draws the records it keeps. Every switch starts as IntelliJ IDEA's console,
// which records none of these queries and draws everything else, so the stored preferences of
// a user who never touched them are empty.

// gitConsoleOption is one switch of the Git console cards: the key of its switch, its title
// and help, the preference it changes and whether the switch shows that preference inverted,
// as an omit switch shows a preference that says to show.
type gitConsoleOption struct {
	key, title, help string
	field            *bool
	inverted         bool
}

// gitConsoleCards declares the two Git console cards for the preferences the window holds.
func (w *window) gitConsoleCards(c ui.C, language i18n.Language) {
	value := w.sess.values.GitConsole
	omitted := [...]gitConsoleOption{
		{"references", i18n.Shared(language, "desktop.git.settings.console.references"), i18n.Shared(language, "desktop.git.settings.console.referencesHelp"), &value.ShowReferenceQueries, true},
		{"reload", i18n.Shared(language, "desktop.git.settings.console.reload"), i18n.Shared(language, "desktop.git.settings.console.reloadHelp"), &value.ShowReloadQueries, true},
		{"diffRefresh", i18n.Shared(language, "desktop.git.settings.console.diffRefresh"), i18n.Shared(language, "desktop.git.settings.console.diffRefreshHelp"), &value.ShowDiffRefreshQueries, true},
		{"diff", i18n.Shared(language, "desktop.git.settings.console.diff"), i18n.Shared(language, "desktop.git.settings.console.diffHelp"), &value.ShowDiffQueries, true},
		{"log", i18n.Shared(language, "desktop.git.settings.console.log"), i18n.Shared(language, "desktop.git.settings.console.logHelp"), &value.ShowLogQueries, true},
		{"logPathFilter", i18n.Shared(language, "desktop.git.settings.console.logPathFilter"), i18n.Shared(language, "desktop.git.settings.console.logPathFilterHelp"), &value.ShowLogPathFilterQueries, true},
		{"annotate", i18n.Shared(language, "desktop.git.settings.console.annotate"), i18n.Shared(language, "desktop.git.settings.console.annotateHelp"), &value.ShowAnnotateQueries, true},
		{"panels", i18n.Shared(language, "desktop.git.settings.console.panels"), i18n.Shared(language, "desktop.git.settings.console.panelsHelp"), &value.ShowPanelQueries, true},
		{"checks", i18n.Shared(language, "desktop.git.settings.console.checks"), i18n.Shared(language, "desktop.git.settings.console.checksHelp"), &value.ShowCheckQueries, true},
	}
	display := [...]gitConsoleOption{
		{"foldShortQueries", i18n.Shared(language, "desktop.git.settings.console.foldShortQueries"), i18n.Shared(language, "desktop.git.settings.console.foldShortQueriesHelp"), &value.FoldShortQueries, false},
		{"completedNotice", i18n.Shared(language, "desktop.git.settings.console.completedNotice"), i18n.Shared(language, "desktop.git.settings.console.completedNoticeHelp"), &value.ShowCompletedWithoutOutput, true},
		{"temporaryConfig", i18n.Shared(language, "desktop.git.settings.console.temporaryConfig"), i18n.Shared(language, "desktop.git.settings.console.temporaryConfigHelp"), &value.HideTemporaryConfig, false},
		{"repository", i18n.Shared(language, "desktop.git.settings.console.repository"), i18n.Shared(language, "desktop.git.settings.console.repositoryHelp"), &value.HideRepository, false},
	}
	w.card(c, i18n.Shared(language, "desktop.git.settings.console.omitted"), i18n.Shared(language, "desktop.git.settings.console.omittedHelp"), func() {
		for _, option := range omitted {
			if w.gitConsoleSwitch(c, option) {
				w.setGitConsole(value, false)
			}
		}
	})
	w.card(c, i18n.Shared(language, "desktop.git.settings.console.display"), i18n.Shared(language, "desktop.git.settings.console.displayHelp"), func() {
		for _, option := range display {
			if w.gitConsoleSwitch(c, option) {
				w.setGitConsole(value, false)
			}
		}
	})
}

// gitConsoleSwitch declares the switch of option with its help glyph and reports whether the
// user flipped it, which it has then written into the preference.
func (w *window) gitConsoleSwitch(c ui.C, option gitConsoleOption) bool {
	on := *option.field != option.inverted
	changed := false
	ui.Row(c).FillWidth().MinHeight(28).Items(ui.Center).Gap(6).Children(func() {
		changed = ui.Switch(c.Part("console-"+option.key), &on, option.title).Changed()
		w.infoButton(c, option.help)
	})
	if changed {
		*option.field = on != option.inverted
	}
	return changed
}

// setGitConsole stores a change of the Git console cards and hands it to the settings owner
// at once.
func (w *window) setGitConsole(value core.GitConsolePreferences, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.GitConsole == value) {
		return
	}
	w.sess.values.GitConsole = value
	if w.ctrl.opts.SetGitConsole != nil {
		w.ctrl.opts.SetGitConsole(value)
	}
}
