package settingswindow

import (
	"runtime"

	"github.com/vivaui/viva/ui"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TerminalBehavior is the Terminal page's switches (matrix ids terminal-shell-integration and
// terminal-interaction). Each field names the change from the default, so the zero value is
// the default of every switch and a setting stored before a switch existed keeps its default.
// It is Lithe's own preference: no shell's configuration is read or written for it.
type TerminalBehavior struct {
	// DisableShellIntegration starts the user's shell as it is, without the integration that
	// has it report its prompts, its commands and its folder. A terminal takes it when its
	// shell starts, so the shells already running keep what they started with.
	DisableShellIntegration bool `json:"disableShellIntegration,omitempty"`
	// DisableClickMove keeps a click on the line being typed from moving the shell's cursor
	// there. Open terminals take it at their next paint.
	DisableClickMove bool `json:"disableClickMove,omitempty"`
	// OptionAsMeta makes Option the Meta key on macOS: an Option chord reaches the program as
	// Escape and the key, instead of the character Option types. Open terminals take it at
	// their next paint; other platforms ignore it, as their Alt already is the Meta key.
	OptionAsMeta bool `json:"optionAsMeta,omitempty"`
}

// optionAsMetaOffered is whether the page offers the Option switch: only macOS has an Option
// key that types characters. Tests set it to see the page of the other platforms.
var optionAsMetaOffered = runtime.GOOS == "darwin"

// behaviorCard is the Terminal page's switches: the shell integration and the click that
// moves the cursor, both on by default, and on macOS Option as the Meta key, off by default.
// Each switch hands its change to the settings owner at once.
func (w *window) behaviorCard(c ui.C) {
	language := w.marketLanguage()
	behavior := w.sess.values.TerminalBehavior
	integration, clickMove, optionMeta := !behavior.DisableShellIntegration, !behavior.DisableClickMove, behavior.OptionAsMeta
	w.card(c, i18n.Shared(language, "desktop.settings.terminal.behavior"), "", func() {
		w.behaviorSwitch(c, "shell-integration", &integration, i18n.Shared(language, "desktop.settings.terminal.shellIntegration"),
			i18n.Shared(language, "desktop.settings.terminal.shellIntegrationHelp"), func() {
				behavior.DisableShellIntegration = !integration
			})
		w.behaviorSwitch(c, "click-move", &clickMove, i18n.Shared(language, "desktop.settings.terminal.clickMove"),
			i18n.Shared(language, "desktop.settings.terminal.clickMoveHelp"), func() {
				behavior.DisableClickMove = !clickMove
			})
		if optionAsMetaOffered {
			w.behaviorSwitch(c, "option-meta", &optionMeta, i18n.Shared(language, "desktop.settings.terminal.optionAsMeta"),
				i18n.Shared(language, "desktop.settings.terminal.optionAsMetaHelp"), func() {
					behavior.OptionAsMeta = optionMeta
				})
		}
	})
	w.setTerminalBehavior(behavior, false)
}

// behaviorSwitch is one switch of the card with its ⓘ. changed runs when the user flipped it.
func (w *window) behaviorSwitch(c ui.C, part string, on *bool, title, help string, changed func()) {
	ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(6).Children(func() {
		if ui.Switch(c.Part(part), on, title).Changed() {
			changed()
		}
		w.infoButton(c, help)
	})
}

// setTerminalBehavior stores the switches and hands them to the settings owner when they
// changed, or when force asks for it.
func (w *window) setTerminalBehavior(value TerminalBehavior, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.TerminalBehavior == value) {
		return
	}
	w.sess.values.TerminalBehavior = value
	if w.ctrl.opts.SetTerminalBehavior != nil {
		w.ctrl.opts.SetTerminalBehavior(value)
	}
}
