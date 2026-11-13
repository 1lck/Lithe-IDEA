package settingswindow

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Choices of the Process Termination page's selects. They are what a choice stores, so
// "ask" is the empty value: Core's default.
var (
	runServiceChoices   = []string{"", RunServicesTerminate}
	terminalChoices     = []string{"", TerminalsTerminate}
	startupSweepChoices = []string{"", StartupSweepTerminate}
)

// stopTimeFieldID is the Process Termination page's stop time field.
var stopTimeFieldID = gfx.Item(4)

// processTerminationPage is the Process Termination page: whether closing a project or
// quitting asks before it stops Run sessions and ends terminals that run a program, whether
// closing a busy terminal tab asks, whether the next start asks about the terminals a crash
// left running, and how long a stopped program gets to exit. Core decides from these values
// (see processLifecycle.resolve); the page only edits them. Opening it writes nothing, and a
// change reaches the settings owner at once.
func (w *window) processTerminationPage(c ui.C) {
	language := w.marketLanguage()
	value := w.sess.values.ProcessTermination
	runServices, terminals := value.RunServicesOnExit, value.TerminalOnQuit
	confirmTab := value.ConfirmTerminalTabClose == nil || *value.ConfirmTerminalTabClose
	w.pageScroll(c, pageProcessTermination, func() {
		w.card(c, i18n.Shared(language, "native.whenQuittingLithe"), "", func() {
			runTitle := i18n.Shared(language, "desktop.settings.processTermination.runServices")
			w.settingsRow(c.Part("run-row"), runTitle, i18n.Shared(language, "desktop.settings.processTermination.runServicesHelp"), func() {
				label := func(choice string) string {
					if choice == RunServicesTerminate {
						return i18n.Shared(language, "desktop.settings.processTermination.stopWithoutAsking")
					}
					return i18n.Shared(language, "desktop.settings.processTermination.askBeforeStopping")
				}
				if ui.Select(c.Part("run"), &runServices, runServiceChoices, label).Width(selectWidth).Label(runTitle).Changed() {
					value.RunServicesOnExit = runServices
					w.setProcessTermination(value, false)
				}
			})
			terminalTitle := i18n.Shared(language, "desktop.settings.processTermination.onQuit")
			w.settingsRow(c.Part("terminal-row"), terminalTitle, i18n.Shared(language, "desktop.settings.processTermination.terminalsHelp"), func() {
				label := func(choice string) string {
					if choice == TerminalsTerminate {
						return i18n.Shared(language, "desktop.settings.processTermination.endWithoutAsking")
					}
					return i18n.Shared(language, "desktop.settings.processTermination.askBeforeEnding")
				}
				if ui.Select(c.Part("quit"), &terminals, terminalChoices, label).Width(selectWidth).Label(terminalTitle).Changed() {
					value.TerminalOnQuit = terminals
					w.setProcessTermination(value, false)
				}
			})
		})
		w.card(c, i18n.Shared(language, "native.closingATerminalTab"), "", func() {
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
		if w.ctrl.opts.SweepsLeftovers {
			w.card(c, i18n.Shared(language, "native.afterLitheClosesUnexpectedly"), i18n.Shared(language, "desktop.settings.processTermination.startupSweepHelp"), func() {
				sweep := value.StartupSweep
				label := func(choice string) string {
					if choice == StartupSweepTerminate {
						return i18n.Shared(language, "native.endOnNextLaunch")
					}
					return i18n.Shared(language, "native.askOnNextLaunch")
				}
				ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
					ui.Text(c, i18n.Shared(language, "desktop.settings.processTermination.leftoverTerminals")).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
					if ui.Select(c.Part("sweep"), &sweep, startupSweepChoices, label).Width(selectWidth).
						Label(i18n.Shared(language, "desktop.settings.processTermination.leftoverTerminals")).Changed() {
						value.StartupSweep = sweep
						w.setProcessTermination(value, false)
					}
				})
			})
		}
		if w.ctrl.opts.StopTime != nil {
			w.stopTimeCard(c, value)
		}
	})
}

// stopTimeCard is the Process Termination page's stop time: the seconds a stopped program
// gets to exit, a second less or more, and Core's default again. Typing a number applies it
// on Enter or when the field loses the keyboard, kept within Core's limits; the field then
// shows what was stored. Until Core has given its rule the controls are disabled.
func (w *window) stopTimeCard(c ui.C, value ProcessTermination) {
	language := w.marketLanguage()
	rule, known := w.ctrl.opts.StopTime()
	seconds := rule.Seconds(value)
	field := &w.stopTimeField
	if !w.stopTimeEditing {
		field.SetText(strconv.Itoa(seconds))
		if !known {
			field.SetText("")
		}
	}
	title := i18n.Shared(language, "native.timeToExit")
	w.card(c, i18n.Shared(language, "native.stoppingPrograms"), i18n.Shared(language, "native.litheFirstAsksEachProgramToStopGivingItThisLongToSaveItsWorkAndExitProgramsStiffc3767044"), func() {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, title).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
			if ui.Button(c.Part("shorter"), i18n.Shared(language, "desktop.settings.processTermination.stopTimeShorter")).Icon(icons.Minus).IconOnly().Ghost().Small().Disabled(!known || seconds <= rule.Min).Clicked() {
				w.setStopTime(value, rule, seconds-1)
			}
			box := ui.TextFieldID(c, stopTimeFieldID, field, title, "").Width(60).Disabled(!known)
			box.OnKey(func(event gfx.KeyEvent) gfx.EventResult {
				if event.Key == gfx.KeyEnter && !event.Release {
					w.commitStopTime(value, rule)
					return gfx.EventResult{Handled: true, Repaint: true}
				}
				return gfx.EventResult{}
			})
			focused := c.Canvas().Focused() == stopTimeFieldID
			if known && focused && strings.TrimSpace(field.Text()) != strconv.Itoa(seconds) {
				w.stopTimeEditing = true
			}
			if w.stopTimeEditing && !focused {
				w.commitStopTime(value, rule)
			}
			ui.Text(c, i18n.Shared(language, "desktop.settings.processTermination.seconds")).FontSize(12).Color(w.pal.text).Shrink(0)
			if ui.Button(c.Part("longer"), i18n.Shared(language, "desktop.settings.processTermination.stopTimeLonger")).Icon(icons.Plus).IconOnly().Ghost().Small().Disabled(!known || seconds >= rule.Max).Clicked() {
				w.setStopTime(value, rule, seconds+1)
			}
			if ui.Button(c.Part("default"), i18n.Shared(language, "native.restoreDefault")).Ghost().Small().Disabled(value.GracefulStopSeconds == nil).Clicked() {
				value.GracefulStopSeconds = nil
				w.setProcessTermination(value, false)
			}
		})
	})
}

// commitStopTime applies the number typed in the stop time field, or puts the stored time
// back when the text is not a number.
func (w *window) commitStopTime(value ProcessTermination, rule StopTime) {
	w.stopTimeEditing = false
	if seconds, err := strconv.Atoi(strings.TrimSpace(w.stopTimeField.Text())); err == nil {
		w.setStopTime(value, rule, seconds)
	}
}

// setStopTime stores seconds as the stop time, kept within Core's limits.
func (w *window) setStopTime(value ProcessTermination, rule StopTime, seconds int) {
	stored := uint32(min(max(seconds, rule.Min), rule.Max))
	value.GracefulStopSeconds = &stored
	w.setProcessTermination(value, false)
}
