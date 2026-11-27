package workbench

import (
	"testing"

	"github.com/vivaui/viva/app"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
)

// The stored switches name the options every terminal takes; the zero value is the default of
// each.
func TestTerminalOptionsFollowTheStoredSwitches(t *testing.T) {
	tests := []struct {
		behavior settingswindow.TerminalBehavior
		want     termview.Options
	}{
		{settingswindow.TerminalBehavior{}, termview.Options{}},
		{settingswindow.TerminalBehavior{DisableShellIntegration: true}, termview.Options{PlainShell: true}},
		{settingswindow.TerminalBehavior{DisableClickMove: true, OptionAsMeta: true}, termview.Options{NoClickMove: true, OptionAsMeta: true}},
	}
	for _, test := range tests {
		a := &App{settings: settings{TerminalBehavior: test.behavior}}
		if got := a.terminalOptions(); got != test.want {
			t.Errorf("%+v: options %+v, want %+v", test.behavior, got, test.want)
		}
	}
}

// A switch flipped on the Terminal page is stored and reaches a terminal already open at its
// next paint.
func TestFlippedTerminalSwitchesReachOpenTerminals(t *testing.T) {
	h, terminal, _ := pasteTerminal(t, nil)
	h.settle()
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.click(center(h.button(itemTerminal)))
	}
	h.settle()
	if terminal.hit.IsZero() {
		t.Fatal("the terminal is not shown")
	}
	altSendsEscape := func() bool {
		input := terminal.view.TextInput(app.TextInputContext{ID: terminal.hit})
		if input == nil {
			t.Fatal("the shown terminal has no text input")
		}
		return input.AltSendsEscape
	}
	if altSendsEscape() {
		t.Fatal("Option sends Escape before the switch is on")
	}

	// The settings window's SetTerminalBehavior hands the change over like this.
	flipped := settingswindow.TerminalBehavior{OptionAsMeta: true, DisableClickMove: true}
	h.app.post(func(a *App) { a.setTerminalBehavior(flipped) })
	h.settle()
	if !altSendsEscape() {
		t.Fatal("the open terminal did not take Option as Meta")
	}
	h.settle()
	var stored settings
	if _, err := h.app.store.Load(settingsFile, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.TerminalBehavior != flipped {
		t.Fatalf("stored %+v, want %+v", stored.TerminalBehavior, flipped)
	}
}
