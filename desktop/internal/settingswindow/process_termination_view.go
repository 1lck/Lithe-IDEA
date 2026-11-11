package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Choices of the Process Termination page's selects. They are what a choice stores, so
// "ask" is the empty value: Core's default.
var (
	runServiceChoices = []string{"", RunServicesTerminate}
	terminalChoices   = []string{"", TerminalsTerminate}
)

// processTerminationPage is the Process Termination page: whether closing a project or
// quitting asks before it stops Run sessions and ends terminals that run a program, and
// whether closing a busy terminal tab asks. Core decides from these values (see
// processLifecycle.resolve); the page only edits them. Opening it writes nothing, and a
// change reaches the settings owner at once.
func (w *window) processTerminationPage(c ui.C) {
	language := w.marketLanguage()
	value := w.sess.values.ProcessTermination
	runServices, terminals := value.RunServicesOnExit, value.TerminalOnQuit
	confirmTab := value.ConfirmTerminalTabClose == nil || *value.ConfirmTerminalTabClose
	w.pageScroll(c, pageProcessTermination, func() {
		w.card(c, i18n.Shared(language, "desktop.settings.processTermination.runServices"), i18n.Shared(language, "desktop.settings.processTermination.runServicesHelp"), func() {
			label := func(choice string) string {
				if choice == RunServicesTerminate {
					return i18n.Shared(language, "desktop.settings.processTermination.stopWithoutAsking")
				}
				return i18n.Shared(language, "desktop.settings.processTermination.askBeforeStopping")
			}
			if ui.Select(c.Part("run"), &runServices, runServiceChoices, label).Width(selectWidth).
				Label(i18n.Shared(language, "desktop.settings.processTermination.runServices")).Changed() {
				value.RunServicesOnExit = runServices
				w.setProcessTermination(value, false)
			}
		})
		w.card(c, i18n.Shared(language, "desktop.settings.processTermination.terminals"), i18n.Shared(language, "desktop.settings.processTermination.terminalsHelp"), func() {
			label := func(choice string) string {
				if choice == TerminalsTerminate {
					return i18n.Shared(language, "desktop.settings.processTermination.endWithoutAsking")
				}
				return i18n.Shared(language, "desktop.settings.processTermination.askBeforeEnding")
			}
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.settings.processTermination.onQuit")).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
				if ui.Select(c.Part("quit"), &terminals, terminalChoices, label).Width(selectWidth).
					Label(i18n.Shared(language, "desktop.settings.processTermination.onQuit")).Changed() {
					value.TerminalOnQuit = terminals
					w.setProcessTermination(value, false)
				}
			})
			if ui.Switch(c.Part("tab"), &confirmTab, i18n.Shared(language, "desktop.settings.processTermination.confirmTabClose")).Changed() {
				if confirmTab {
					value.ConfirmTerminalTabClose = nil
				} else {
					off := false
					value.ConfirmTerminalTabClose = &off
				}
				w.setProcessTermination(value, false)
			}
		})
	})
}
