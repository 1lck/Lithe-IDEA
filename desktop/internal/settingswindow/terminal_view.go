package settingswindow

import (
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/ui"
)

// terminalShellScope holds the options of the default shell choice, one item each:
// the automatic option, the row that names a stored shell no installed shell matches, and
// the installed shells from terminalFirstShellItem on, in the order the loader listed them.
// An option keeps its item whichever of the others are shown, so the focus stays on it.
var terminalShellScope = tree.Sub(root, tree.Name("terminal-shell"))

const (
	terminalAutomaticItem = 0
	terminalMissingItem   = 1
	// terminalFirstShellItem is the item of the first installed shell.
	terminalFirstShellItem = 2
	// terminalInfoIndex is the item of infoScope that belongs to the Terminal page's card:
	// the general page uses 0 to 3 and the editor page 4.
	terminalInfoIndex = 5
)

// terminalShellResult is what one load of the installed shells found.
type terminalShellResult struct {
	shells []localshell.Choice
	// automatic is the program a new terminal runs when no shell is chosen; empty when the
	// system names none.
	automatic string
}

// terminalShellState is the Terminal page's list of installed shells. Only the window
// thread reads or writes the fields. The one worker owns the loader and the result channel
// and hands the result over through that channel; the window thread takes it in drain.
type terminalShellState struct {
	load func() ([]localshell.Choice, string)
	// wake repaints the window once the worker has finished and finished says the window
	// is gone, in which case the worker neither repaints it nor is waited for.
	wake     func()
	finished func() bool
	// results has room for the one result a window ever gets, so the worker never waits
	// for a reader.
	results chan terminalShellResult

	started bool
	loaded  bool
	shells  []localshell.Choice
	// automatic is the program automatic runs, as the loader named it.
	automatic string

	// labels are the words of shells in the language of labelsFor, built when the page first
	// needs them and again when the language or the list changes.
	labels    []string
	labelsFor *i18n.SettingsMessages
}

func newTerminalShellState(load func() ([]localshell.Choice, string), wake func(), finished func() bool) terminalShellState {
	return terminalShellState{load: load, wake: wake, finished: finished, results: make(chan terminalShellResult, 1)}
}

// begin starts the one load a window makes, off the window thread, the first time the page
// is drawn. It does nothing again afterwards, with no loader, or once the window is gone.
// The load reads the machine and writes nothing.
func (s *terminalShellState) begin() {
	if s.load == nil || s.started || (s.finished != nil && s.finished()) {
		return
	}
	s.started = true
	load, wake, finished, results := s.load, s.wake, s.finished, s.results
	go func() {
		shells, automatic := load()
		results <- terminalShellResult{shells: shells, automatic: automatic}
		if wake != nil && (finished == nil || !finished()) {
			wake()
		}
	}()
}

// drain takes the finished load on the window thread. It is called at the start of each
// paint.
func (s *terminalShellState) drain() {
	select {
	case result := <-s.results:
		s.shells, s.automatic, s.loaded = result.shells, result.automatic, true
		s.labels, s.labelsFor = nil, nil
	default:
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

// drawTerminal is the Terminal page. Its card chooses the shell a new terminal runs:
// automatic, which is the system's default shell and says which that is, or one of the
// installed shells. A stored shell that is no longer installed stays chosen and is named as
// not found, instead of being swapped for one that exists, so the stored value is changed
// only by the user. Opening the page writes nothing.
func (w *window) drawTerminal(f *ui.Frame) {
	settings := &w.text.Settings
	state := &w.terminal
	state.begin()
	stored := w.sess.values.TerminalShell
	scroll := pageScrollScope.At(int(pageTerminal))
	f.ScrollArea(scroll).Grow(1).Shrink(1).MinHeight(0).PadSides(18, contentPad, contentPad, contentPad).Gap(cardGap).Children(func() {
		w.card(f, terminalInfoIndex, settings.TerminalShell, settings.TerminalShellHelp, func() {
			f.Column().FillWidth().Gap(2).Children(func() {
				loading := !state.loaded
				if w.radio(f, terminalShellScope.At(terminalAutomaticItem), settings.TerminalShellAuto(state.effective(settings)), stored == "", loading) {
					w.setTerminalShell("", false)
				}
				if loading {
					// Whether a stored shell is installed is not known yet. It stays chosen,
					// named by its path, and cannot be clicked until the list is here.
					if stored != "" {
						w.radio(f, terminalShellScope.At(terminalMissingItem), stored, true, true)
					}
					return
				}
				labels := state.shellLabels(settings)
				known := stored == ""
				for index, choice := range state.shells {
					chosen := stored != "" && sameShell(choice.Path, stored)
					known = known || chosen
					if w.radio(f, terminalShellScope.At(terminalFirstShellItem+index), labels[index], chosen, false) {
						w.setTerminalShell(choice.Path, false)
					}
				}
				if !known {
					// Already chosen, so a click on it changes nothing.
					w.radio(f, terminalShellScope.At(terminalMissingItem), settings.TerminalShellMissing(stored), true, false)
				}
			})
		})
	})
}
