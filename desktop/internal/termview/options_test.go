package termview

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// With the shell integration off the user's shell starts without a token, so nothing it prints
// counts as a prompt. The switch applies from the next start: the shell running keeps its own.
func TestPlainShellStartsTheUsersShellWithoutIntegration(t *testing.T) {
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{})}
	view := newFakeView(shell, Config{Shell: "/bin/zsh"}, &started)
	t.Cleanup(func() { view.Close() })
	view.SetOptions(Options{PlainShell: true})
	view.ensureStarted()
	if started.PromptToken != "" {
		t.Fatalf("the plain shell started with token %q", started.PromptToken)
	}
	output(view, shell, "\x1b]133;C;motty=\a\x1b]133;C\a")
	if view.screen.CommandReporting() {
		t.Fatal("a plain shell's output counted as a command mark")
	}

	view.SetOptions(Options{})
	close(shell.done)
	view.Pump()
	shell.done = make(chan struct{})
	if !view.restart() {
		t.Fatal("the ended shell did not restart")
	}
	if started.PromptToken == "" {
		t.Fatal("the shell started after the integration came back on has no token")
	}
}

// With click-to-move off a click on the line being typed sends nothing, with or without Option,
// and turning it back on applies to the next click.
func TestNoClickMoveLeavesTheShellCursorWhereItIs(t *testing.T) {
	rig := newInputRig(t)
	rig.view.SetOptions(Options{NoClickMove: true})
	clickCell(rig, 0, 5, 0)
	clickCell(rig, 0, 3, gfx.ModifierAlt)
	if got := string(rig.shell.input); got != "" {
		t.Fatalf("the clicks sent %q with click-to-move off", got)
	}
	rig.view.SetOptions(Options{})
	clickCell(rig, 0, 5, 0)
	if got, want := string(rig.shell.input), "\x1b[D\x1b[D"; got != want {
		t.Fatalf("the click sent %q, want %q once click-to-move is back on", got, want)
	}
}

// Option stays a composing key by default. With Option as Meta the text system hands Option
// chords over as keys, and the key reaches the shell as Escape and the letter.
func TestOptionAsMetaSendsOptionChordsAsEscapeAndTheKey(t *testing.T) {
	rig := newInputRig(t)
	context := app.TextInputContext{ID: gfx.Item(1)}
	if rig.view.TextInput(context).AltSendsEscape {
		t.Fatal("Option sends Escape before the switch is on")
	}
	rig.view.SetOptions(Options{OptionAsMeta: true})
	if !rig.view.TextInput(context).AltSendsEscape {
		t.Fatal("the switch did not reach the text system")
	}
	if _, ok := rig.view.Key(gfx.KeyEvent{Target: gfx.Item(1), Key: gfx.KeyUnknown, Text: "b", Modifiers: gfx.ModifierAlt}); !ok {
		t.Fatal("the terminal did not take the Option chord")
	}
	if got, want := string(rig.shell.input), "\x1bb"; got != want {
		t.Fatalf("Option+B sent %q, want %q", got, want)
	}
	rig.view.SetOptions(Options{})
	if rig.view.TextInput(context).AltSendsEscape {
		t.Fatal("Option still sends Escape after the switch went off")
	}
}
