package termview

import (
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
)

// newShellMenuView is a started view running a shell of the given kind the way the shell
// menu starts one, or with args of its own when args is not nil, as a plugin terminal is.
func newShellMenuView(t *testing.T, kind shellkind.Kind, args []string) (*View, *fakeShell) {
	t.Helper()
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{}), kind: kind}
	view := newFakeView(shell, Config{Shell: "pwsh", Args: args}, &started)
	t.Cleanup(func() { view.Close() })
	view.ensureStarted()
	view.screen.Resize(40, 6)
	return view, shell
}

// PowerShell at its prompt gets a form feed after the clear, so its line editor writes
// the line at the top instead of at the row it was on before the clear.
func TestClearSendsAFormFeedToPowerShellAtItsPrompt(t *testing.T) {
	view, shell := newShellMenuView(t, shellkind.PowerShell, nil)
	output(view, shell, "PS C:\\> dir\r\nfile\r\nPS C:\\> ")
	view.Clear()
	if got := string(shell.input); got != "\f" {
		t.Fatalf("shell input = %q, want a form feed", got)
	}
	if got := view.screen.Text(); !strings.HasPrefix(got, "PS C:\\>") {
		t.Fatalf("screen after the clear = %q, want the prompt line at the top", got)
	}
}

// The form feed goes only to PowerShell's own line editor: never to a program it runs,
// to another shell, to a plugin's program, or after a clear the alternate screen refused.
func TestClearSendsNoFormFeedWhereNoLineEditorReadsIt(t *testing.T) {
	for _, test := range []struct {
		name   string
		kind   shellkind.Kind
		args   []string
		busy   bool
		output string
	}{
		{name: "a program runs", kind: shellkind.PowerShell, busy: true, output: "Password: "},
		{name: "cmd", kind: shellkind.Cmd, output: "C:\\>"},
		{name: "posix", kind: shellkind.POSIX, output: "prompt$ "},
		{name: "unknown", kind: shellkind.Unknown, output: "prompt$ "},
		{name: "a plugin's program", kind: shellkind.PowerShell, args: []string{"-File", "tool.ps1"}, output: "tool> "},
		{name: "alternate screen", kind: shellkind.PowerShell, output: "\x1b[?1049hfull screen"},
	} {
		t.Run(test.name, func(t *testing.T) {
			view, shell := newShellMenuView(t, test.kind, test.args)
			shell.busy = test.busy
			output(view, shell, test.output)
			view.Clear()
			if strings.Contains(string(shell.input), "\f") {
				t.Fatalf("shell input = %q, want no form feed", shell.input)
			}
		})
	}
}
