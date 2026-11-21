package termview

import (
	"errors"
	"strings"
	"testing"
)

// A program Config.Open starts elsewhere is given the screen's size and nothing of the local
// shell's start: its output is shown and what is typed is written to it. A failure to open is
// shown with its reason, logged and ends the view, and Enter opens the program again.
func TestOpenStartsTheProgramElsewhere(t *testing.T) {
	var sizes [][2]int
	refusal := errors.New("the host is not connected")
	refuse := true
	shell := &fakeShell{done: make(chan struct{}), output: []byte("host$ ")}
	var failures []Failure
	view := New(Config{
		Shell: "ignored", Dir: "/ignored",
		Messages: Messages{
			SessionEnded:       "ended",
			SessionEndedStatus: func(int) string { return "ended with status" },
			RestartHint:        "press enter",
			StartFailed:        func(reason string) string { return "could not start: " + reason },
		},
		Failed: func(f Failure) { failures = append(failures, f) },
		Open: func(cols, rows int) (Shell, error) {
			sizes = append(sizes, [2]int{cols, rows})
			if refuse {
				refuse = false
				return nil, refusal
			}
			return shell, nil
		},
	})
	view.ensureStarted()
	cols, rows := view.screen.Size()
	if len(sizes) != 1 || sizes[0] != [2]int{cols, rows} {
		t.Fatalf("opened with %v, want the screen's %dx%d", sizes, cols, rows)
	}
	if !view.Ended() || !strings.Contains(view.RetainedText(1<<16), "could not start: the host is not connected") {
		t.Fatalf("a failed open shows %q and ended = %v", view.RetainedText(1<<16), view.Ended())
	}
	if len(failures) != 1 || failures[0].Event != eventStartFailed || !errors.Is(failures[0].Err, refusal) {
		t.Fatalf("failures = %+v, want the start failure", failures)
	}

	if !view.Restart() {
		t.Fatal("Enter did not open the program again")
	}
	view.Pump()
	if len(sizes) != 2 || view.Ended() || !strings.Contains(view.RetainedText(1<<16), "host$") {
		t.Fatalf("opened %d times; the view shows %q", len(sizes), view.RetainedText(1<<16))
	}
	if !view.SendLine("ls") || !strings.Contains(string(shell.input), "ls") {
		t.Fatalf("the program was given %q", shell.input)
	}
}
