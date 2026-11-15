package settingswindow

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"runtime"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/ui"
)

// terminalShellResult is what one load of the installed shells found.
type terminalShellResult struct {
	shells []localshell.Choice
	// automatic is the program a new terminal runs when no shell is chosen; empty when the
	// system names none.
	automatic string
}

// terminalShellState is the Terminal page's list of installed shells. Only the window
// thread reads or writes the fields. The load is a page Effect: it starts the first time
// the page is drawn, the window takes its result with take at the start of a paint, and
// closing the window cancels it.
type terminalShellState struct {
	load   func() ([]localshell.Choice, string)
	effect *ui.EffectState[terminalShellResult, int]
	// key is zero until the Terminal page asks for the load.
	key int

	loaded bool
	shells []localshell.Choice
	// automatic is the program automatic runs, as the loader named it.
	automatic string

	// labels are the words of shells in the language of labelsFor, built when the page first
	// needs them and again when the language or the list changes.
	labels    []string
	labelsFor *i18n.SettingsMessages
}

func newTerminalShellState(load func() ([]localshell.Choice, string)) terminalShellState {
	s := terminalShellState{load: load}
	if load != nil {
		s.effect = ui.NewEffect[terminalShellResult, int](func(context.Context) (terminalShellResult, error) {
			shells, automatic := load()
			return terminalShellResult{shells: shells, automatic: automatic}, nil
		})
	}
	return s
}

// begin asks for the one load a window makes the first time the page is drawn. It does
// nothing again afterwards or with no loader. The load reads the machine and writes nothing.
func (s *terminalShellState) begin() {
	if s.load == nil || s.key != 0 {
		return
	}
	s.key = 1
}

// take applies the finished load on the window thread at the start of a paint.
func (s *terminalShellState) take() {
	if s.effect == nil {
		return
	}
	if result, _, ok := s.effect.Take(); ok {
		s.shells, s.automatic, s.loaded = result.shells, result.automatic, true
		s.labels, s.labelsFor = nil, nil
	}
}

// declare keeps the load alive until the page ends. It is declared from every paint, so
// leaving the page does not cancel a load that is out.
func (s *terminalShellState) declare(c ui.C) {
	if s.effect != nil && s.key != 0 {
		ui.Effect(c, s.effect, s.key)
	}
}

// shellLabels are the words of the installed shells: a name that only one shell has stands
// alone, and shells that share a name are told apart by their path.
func (s *terminalShellState) shellLabels(settings *i18n.SettingsMessages) []string {
	if s.labels == nil || s.labelsFor != settings {
		s.labels = localshell.Labels(s.shells, settings.ShellWithPath)
		s.labelsFor = settings
	}
	return s.labels
}

// effective is what automatic is shown to run: the words of the installed shell it runs,
// else the program itself, and while the load is out or when the system names no program,
// the reason there is nothing to show yet.
func (s *terminalShellState) effective(settings *i18n.SettingsMessages) string {
	if !s.loaded {
		return settings.DetectingShells
	}
	if s.automatic == "" {
		return settings.NoShells
	}
	labels := s.shellLabels(settings)
	for index, choice := range s.shells {
		if choice.Default || sameShell(choice.Path, s.automatic) {
			return labels[index]
		}
	}
	return s.automatic
}

// sameShell says whether two paths name the same shell program. Windows compares paths
// without regard to case.
func sameShell(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// terminalPage is the Terminal page. Its card chooses the shell a new terminal runs:
// automatic, which is the system's default shell and says which that is, or one of the
// installed shells. A stored shell that is no longer installed stays chosen and is named as
// not found, instead of being swapped for one that exists, so the stored value is changed
// only by the user. Opening the page writes nothing.
func (w *window) terminalPage(c ui.C) {
	settings := &w.text.Settings
	state := &w.terminal
	state.begin()
	stored := w.sess.values.TerminalShell
	w.shellPick = stored
	// A stored path that names an installed shell in another spelling (Windows ignores
	// case) shows that shell as chosen.
	for _, choice := range state.shells {
		if stored != "" && sameShell(choice.Path, stored) {
			w.shellPick = choice.Path
		}
	}
	w.pageScroll(c, pageTerminal, func() {
		w.card(c, settings.TerminalShell, settings.TerminalShellHelp, func() {
			choices := make([]string, 1, len(state.shells)+2)
			labels := state.shellLabels(settings)
			known := stored == ""
			for _, choice := range state.shells {
				choices = append(choices, choice.Path)
				known = known || (stored != "" && sameShell(choice.Path, stored))
			}
			if !known {
				choices = append(choices, stored)
			}
			label := func(path string) string {
				if path == "" {
					return settings.TerminalShellAuto(state.effective(settings))
				}
				for i, choice := range state.shells {
					if path == choice.Path {
						return labels[i]
					}
				}
				if !state.loaded {
					return path
				}
				return settings.TerminalShellMissing(path)
			}
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				ui.Text(c, settings.TerminalShell).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
				ui.Select(c.Part("shell"), &w.shellPick, choices, label).Width(selectWidth).Label(settings.TerminalShell).Disabled(!state.loaded)
			})
		})
		w.scrollbackCard(c)
	})
	if w.shellPick != stored && !(stored != "" && sameShell(w.shellPick, stored)) {
		w.setTerminalShell(w.shellPick, false)
	}
}

// The Terminal page's history limits: what a new terminal keeps above its screen.
const (
	DefaultScrollback = 2000
	MinScrollback     = 100
	MaxScrollback     = 50000
	scrollbackStep    = 500
)

// scrollbackFieldID is the Terminal page's history field.
var scrollbackFieldID = gfx.Item(3)

// ClampScrollback is lines within the page's limits; zero is the default.
func ClampScrollback(lines int) int {
	if lines == 0 {
		return DefaultScrollback
	}
	return min(max(lines, MinScrollback), MaxScrollback)
}

// scrollbackCard is the Terminal page's history setting: the number of lines, steps of
// 500 either way, and the default again. Typing a number applies it on Enter or when the
// field loses the keyboard, clamped to the limits; the field then shows what was stored.
func (w *window) scrollbackCard(c ui.C) {
	language := w.marketLanguage()
	value := ClampScrollback(w.sess.values.TerminalScrollback)
	field := &w.scrollbackField
	if !w.scrollbackEditing {
		field.SetText(strconv.Itoa(value))
	}
	title := i18n.Shared(language, "desktop.settings.terminal.scrollback")
	w.card(c, title, i18n.Shared(language, "desktop.settings.terminal.scrollbackHelp"), func() {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.settings.terminal.scrollbackLines")).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
			if ui.Button(c.Part("less"), i18n.Shared(language, "desktop.settings.terminal.scrollbackLess")).Icon(icons.Minus).IconOnly().Ghost().Small().Disabled(value <= MinScrollback).Clicked() {
				w.setTerminalScrollback(value - scrollbackStep)
			}
			box := ui.TextFieldID(c, scrollbackFieldID, field, title, "").Width(90)
			box.OnKey(func(event gfx.KeyEvent) gfx.EventResult {
				if event.Key == gfx.KeyEnter && !event.Release {
					w.commitScrollback()
					return gfx.EventResult{Handled: true, Repaint: true}
				}
				return gfx.EventResult{}
			})
			focused := c.Canvas().Focused() == scrollbackFieldID
			if focused && strings.TrimSpace(field.Text()) != strconv.Itoa(value) {
				w.scrollbackEditing = true
			}
			if w.scrollbackEditing && !focused {
				w.commitScrollback()
			}
			if ui.Button(c.Part("more"), i18n.Shared(language, "desktop.settings.terminal.scrollbackMore")).Icon(icons.Plus).IconOnly().Ghost().Small().Disabled(value >= MaxScrollback).Clicked() {
				w.setTerminalScrollback(value + scrollbackStep)
			}
			if ui.Button(c.Part("default"), i18n.Shared(language, "desktop.settings.terminal.scrollbackDefault")).Ghost().Small().Disabled(value == DefaultScrollback).Clicked() {
				w.setTerminalScrollback(DefaultScrollback)
			}
		})
	})
}

// commitScrollback applies the number typed in the history field, or puts the stored one
// back when the text is not a number.
func (w *window) commitScrollback() {
	w.scrollbackEditing = false
	if lines, err := strconv.Atoi(strings.TrimSpace(w.scrollbackField.Text())); err == nil {
		w.setTerminalScrollback(lines)
	}
}

// setTerminalScrollback stores the clamped history limit and hands it to the settings owner.
func (w *window) setTerminalScrollback(lines int) {
	if w.sess.finished.Load() {
		return
	}
	lines = ClampScrollback(lines)
	if lines == ClampScrollback(w.sess.values.TerminalScrollback) {
		return
	}
	w.sess.values.TerminalScrollback = lines
	if w.ctrl.opts.SetTerminalScrollback != nil {
		w.ctrl.opts.SetTerminalScrollback(lines)
	}
}
