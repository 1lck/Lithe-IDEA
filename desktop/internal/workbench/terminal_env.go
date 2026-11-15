package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// inheritedColorVariables are variables the window may have inherited (from a CI runner,
// a launcher or a parent terminal) that make command-line tools drop color. A terminal
// starts without them, so an Agent CLI run in it is not reduced to black and white; an
// environment a caller sets explicitly still wins.
var inheritedColorVariables = []string{"NO_COLOR", "FORCE_COLOR", "CLICOLOR_FORCE", "CI", "GITHUB_ACTIONS", "CONTINUOUS_INTEGRATION"}

// terminalEnvironment is what every terminal adds to its environment before the caller's
// own variables: who the terminal is (TERM_PROGRAM, TERM_PROGRAM_VERSION when the
// version is known), the look as COLORFGBG (light 0;15, dark 15;0) so a TUI picks its
// colors without asking, and CLICOLOR.
func (a *App) terminalEnvironment() []string {
	env := []string{"TERM_PROGRAM=Lithe", "CLICOLOR=1"}
	if a.version != "" {
		env = append(env, "TERM_PROGRAM_VERSION="+a.version)
	}
	if a.colors.Dark {
		env = append(env, "COLORFGBG=15;0")
	} else {
		env = append(env, "COLORFGBG=0;15")
	}
	return env
}

// terminalScrollback is the history a new terminal keeps, from the Terminal settings page.
func (a *App) terminalScrollback() int {
	return settingswindow.ClampScrollback(a.settings.TerminalScrollback)
}

// setTerminalScrollback stores the history new terminals keep; open ones keep theirs.
func (a *App) setTerminalScrollback(lines int) {
	lines = settingswindow.ClampScrollback(lines)
	if lines == settingswindow.DefaultScrollback {
		lines = 0
	}
	if a.settings.TerminalScrollback == lines {
		return
	}
	a.settings.TerminalScrollback = lines
	a.saveSettings()
}
