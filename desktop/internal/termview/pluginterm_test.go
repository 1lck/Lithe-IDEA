package termview

import (
	"errors"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

type fakeShell struct {
	output []byte
	done   chan struct{}
	err    error
}

func (s *fakeShell) Drain(dst []byte) []byte {
	dst = append(dst, s.output...)
	s.output = nil
	return dst
}
func (s *fakeShell) Write([]byte) bool     { return true }
func (s *fakeShell) Resize(int, int)       {}
func (s *fakeShell) Done() <-chan struct{} { return s.done }
func (s *fakeShell) Err() error            { return s.err }
func (s *fakeShell) Close()                {}

type exitStatus int

func (e exitStatus) Error() string   { return "exit" }
func (e exitStatus) ExitStatus() int { return int(e) }

func newFakeView(fake *fakeShell, config Config, started *localshell.Config) *View {
	config.Messages = Messages{
		SessionEnded:       "ended",
		SessionEndedStatus: func(status int) string { return "ended with status" },
		StartFailed:        func(reason string) string { return reason },
	}
	config.start = func(c localshell.Config) (shell, error) {
		*started = c
		return fake, nil
	}
	return New(config)
}

// A view with an owner reports the program's end once, with its status, does not
// restart on Enter, and keeps the output as a plain-text snapshot.
func TestOwnedViewReportsItsEndOnceAndKeepsRetainedText(t *testing.T) {
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{}), output: []byte("hello\r\nworld\r\n"), err: exitStatus(3)}
	var statuses []int
	view := newFakeView(shell, Config{
		Shell: "tool", Args: []string{}, Env: []string{"A=1"}, Unset: []string{"B"}, Dir: "/work",
		Prefill: "old line 1\nold line 2",
		Exited: func(status *int) {
			if status == nil {
				statuses = append(statuses, -1)
				return
			}
			statuses = append(statuses, *status)
		},
	}, &started)
	view.ensureStarted()
	if started.Shell != "tool" || started.Args == nil || len(started.Args) != 0 || started.Env[0] != "A=1" || started.Unset[0] != "B" || started.Dir != "/work" {
		t.Fatalf("start config = %+v", started)
	}
	close(shell.done)
	view.Pump()
	view.Pump()
	if len(statuses) != 1 || statuses[0] != 3 {
		t.Fatalf("exit statuses = %v", statuses)
	}
	if view.restart() {
		t.Fatal("an owned view restarted on its own")
	}
	text := view.RetainedText(1 << 20)
	for _, want := range []string{"old line 1", "old line 2", "hello", "world"} {
		if !strings.Contains(text, want) {
			t.Fatalf("retained text lacks %q: %q", want, text)
		}
	}
	if strings.Index(text, "old line 2") > strings.Index(text, "hello") {
		t.Fatalf("the prefill must come before the new run: %q", text)
	}
	if view.RetainedText(0) != "" {
		t.Fatal("a zero budget retained text")
	}
	cut := view.RetainedText(5)
	if len(cut) > 5 || !strings.HasSuffix(strings.TrimRight(text, "\n "), strings.TrimRight(cut, "\n ")) {
		t.Fatalf("budgeted snapshot = %q of %q", cut, text)
	}
}

func TestRetainedTextNeverSplitsACharacter(t *testing.T) {
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{}), output: []byte("ab你好\r\n")}
	view := newFakeView(shell, Config{Shell: "tool"}, &started)
	view.ensureStarted()
	view.Pump()
	for budget := 1; budget < 12; budget++ {
		got := view.RetainedText(budget)
		if !strings.HasSuffix(got, "好") && got != "" && !strings.HasSuffix(strings.TrimSpace(got), "好") {
			t.Fatalf("budget %d: %q", budget, got)
		}
		for _, r := range got {
			if r == '�' {
				t.Fatalf("budget %d split a character: %q", budget, got)
			}
		}
	}
}

func TestStartFailureIsAnExitOfAnOwnedView(t *testing.T) {
	failed := false
	view := New(Config{Shell: "missing", Messages: Messages{StartFailed: func(reason string) string { return reason }}, Exited: func(status *int) { failed = status == nil }, start: func(localshell.Config) (shell, error) {
		return nil, errors.New("not found")
	}})
	view.ensureStarted()
	if !failed {
		t.Fatal("a program that cannot start was not reported as ended")
	}
}
