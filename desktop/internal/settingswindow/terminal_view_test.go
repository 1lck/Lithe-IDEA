package settingswindow

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

func terminalWindow(t *testing.T, stored string, changed *[]string) (*window, *windowDriver) {
	t.Helper()
	w := newWindow(NewController(Options{
		TerminalShells: func() ([]localshell.Choice, string) {
			return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}, {Name: "bash", Path: "/bin/bash"}}, "/bin/zsh"
		},
		SetTerminalShell: func(value string) { *changed = append(*changed, value) },
	}), Values{TerminalShell: stored})
	w.sess.page = pageTerminal
	d := openWindow(t, w)
	d.until("the installed shells", func() bool { return w.terminal.loaded })
	return w, d
}

// TestTerminalShellChoiceWritesOnlyWhenChosen covers the Terminal page: opening it and the
// load of the installed shells write nothing, a click on a shell applies at once, and the
// automatic option clears the stored shell.
func TestTerminalShellChoiceWritesOnlyWhenChosen(t *testing.T) {
	var changed []string
	w, d := terminalWindow(t, "", &changed)
	settings := w.text.Settings
	if len(changed) != 0 {
		t.Fatalf("opening the page wrote %v", changed)
	}
	auto := settings.TerminalShellAuto("zsh")
	if hit := d.hit(auto); !hit.Checked {
		t.Fatalf("automatic is not chosen: %+v", hit)
	}
	d.click("bash")
	if !slices.Equal(changed, []string{"/bin/bash"}) {
		t.Fatalf("bash: %v", changed)
	}
	d.click(auto)
	if !slices.Equal(changed, []string{"/bin/bash", ""}) {
		t.Fatalf("automatic: %v", changed)
	}
}

// TestTerminalStoredShellThatIsGoneStaysChosen covers a stored shell that is no longer
// installed: it is named as not found and stays chosen instead of being swapped for one that
// exists, so only the user changes the stored value.
func TestTerminalStoredShellThatIsGoneStaysChosen(t *testing.T) {
	var changed []string
	w, d := terminalWindow(t, "/opt/gone/fish", &changed)
	missing := w.text.Settings.TerminalShellMissing("/opt/gone/fish")
	if hit := d.hit(missing); !hit.Checked {
		t.Fatalf("the stored shell is not chosen: %+v", hit)
	}
	if len(changed) != 0 {
		t.Fatalf("showing the page replaced the stored shell: %v", changed)
	}
}
