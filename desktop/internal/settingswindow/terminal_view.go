package settingswindow

import (
	"context"
	"runtime"
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
			ui.Column(c).FillWidth().Gap(2).Children(func() {
				loading := !state.loaded
				w.radio(c.Part("automatic"), &w.shellPick, "", settings.TerminalShellAuto(state.effective(settings)), loading)
				if loading {
					// Whether a stored shell is installed is not known yet. It stays chosen,
					// named by its path, and cannot be clicked until the list is here.
					if stored != "" {
						w.radio(c.Part("missing"), &w.shellPick, stored, stored, true)
					}
					return
				}
				labels := state.shellLabels(settings)
				known := stored == ""
				for index, choice := range state.shells {
					known = known || (stored != "" && sameShell(choice.Path, stored))
					w.radio(c.Key(choice.Path), &w.shellPick, choice.Path, labels[index], false)
				}
				if !known {
					// Already chosen, so a click on it changes nothing.
					w.radio(c.Part("missing"), &w.shellPick, stored, settings.TerminalShellMissing(stored), false)
				}
			})
		})
	})
	if w.shellPick != stored && !(stored != "" && sameShell(w.shellPick, stored)) {
		w.setTerminalShell(w.shellPick, false)
	}
}
