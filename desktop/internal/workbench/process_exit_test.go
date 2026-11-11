package workbench

import (
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// TestClosingWithARunningRunAsksFirst: a close while a Run session runs is a
// question Core's plan asks; cancelling keeps the project, its Run and its debug
// session, and stopping closes everything. The debug session alone is never a
// question: Core terminates it silently.
func TestClosingWithARunningRunAsksFirst(t *testing.T) {
	h, p := pausedDebugSession(t)
	p.build.runs = append(p.build.runs, &runEntry{id: "run-1", label: "Serve", running: true})
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	awaitStateWithin(t, h, 20*time.Second, "the exit question", func() bool { return len(h.app.prompts.queue) == 1 })
	if prompt := h.app.prompts.queue[0]; !strings.Contains(prompt.text, "Serve") || strings.Contains(prompt.text, "Debug") {
		t.Fatalf("the question lists %q, want only the Run session", prompt.text)
	}
	if closed || h.app.project != p || p.debug.session == nil {
		t.Fatal("the project closed before the user answered")
	}
	cancel := 0
	h.app.answerPrompt(&cancel)
	h.settle()
	if closed || h.app.project != p || p.debug.session == nil {
		t.Fatal("cancelling must keep the project and its debug session")
	}

	h.app.requestCloseProject(func() { closed = true })
	awaitStateWithin(t, h, 20*time.Second, "the exit question again", func() bool { return len(h.app.prompts.queue) == 1 })
	stop := 1
	h.app.answerPrompt(&stop)
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool { return closed && h.app.project == nil })
}

// TestClosingWithOnlyADebugSessionDoesNotAsk: Core ends a debug adapter without
// a question.
func TestClosingWithOnlyADebugSessionDoesNotAsk(t *testing.T) {
	h, _ := pausedDebugSession(t)
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	awaitStateWithin(t, h, 30*time.Second, "the project to close", func() bool { return closed && h.app.project == nil })
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("a debug session alone asked a question")
	}
}

// TestClosingWithNothingRunningDoesNotAsk keeps closing as it was.
func TestClosingWithNothingRunningDoesNotAsk(t *testing.T) {
	h := debugHarness(t)
	h.open(t.TempDir())
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool { return closed })
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("closing an idle project asked a question")
	}
}

// busyTerminal opens a terminal whose shell runs script with job control on, so a
// command it runs is a foreground job of its own, as in an interactive shell.
func busyTerminal(t *testing.T, h *harness, script string) *terminal {
	t.Helper()
	p := h.app.project
	term := h.app.newTerminalWith(p, terminalOptions{
		shell: "/bin/sh", args: []string{"-c", "set -m; " + script}, dir: p.root, title: "build", activate: true,
	})
	if term == nil {
		t.Fatal("the terminal was not opened")
	}
	term.view.Start()
	return term
}

// awaitBusy waits for the terminal's shell to report want. The foreground job
// changes without any output, so there is no wake to wait on: the probe is polled,
// bounded by a deadline.
func awaitBusy(t *testing.T, term *terminal, want bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if probe := term.view.BusyProbe(); probe != nil && probe() == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the terminal never read busy=%v", want)
		}
		// test-stability: allow(go-real-sleep) reason: the pty's foreground group changes without output or any other event a test could wait on.
		time.Sleep(10 * time.Millisecond)
	}
}

// Closing a terminal tab whose shell runs a program asks first: Cancel keeps the tab
// and its program, Close ends both. A terminal at rest closes without a question.
func TestClosingABusyTerminalTabAsksFirst(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project

	busy := busyTerminal(t, h, "sleep 30; true")
	awaitBusy(t, busy, true)
	h.app.requestCloseTerminal(p, busy.id)
	h.await("the question", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	if prompt := h.app.prompts.queue[0]; prompt.title != "Close the terminal?" || !strings.Contains(prompt.text, "“build”") {
		t.Fatalf("prompt = %q / %q", prompt.title, prompt.text)
	}
	h.clickNamed("Cancel")
	h.settle()
	if p.terms.find(busy.id) == nil || len(h.app.prompts.queue) != 0 {
		t.Fatal("Cancel closed the terminal or left the question open")
	}
	h.app.requestCloseTerminal(p, busy.id)
	h.await("the question again", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	h.clickNamed("Close")
	h.settle()
	if p.terms.find(busy.id) != nil {
		t.Fatal("Close kept the terminal")
	}

	// read is the shell's own builtin: nothing runs in the foreground but the shell.
	idle := busyTerminal(t, h, "read line")
	awaitBusy(t, idle, false)
	h.app.requestCloseTerminal(p, idle.id)
	h.await("the idle terminal to close", func() bool { return p.terms.find(idle.id) == nil })
	if len(h.app.prompts.queue) != 0 {
		t.Fatal("an idle terminal asked before closing")
	}
}

// Closing the project lists a busy terminal with the running programs; a terminal
// at rest is not listed.
func TestClosingAProjectListsItsBusyTerminals(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	busy := busyTerminal(t, h, "sleep 30; true")
	idle := busyTerminal(t, h, "read line")
	awaitBusy(t, busy, true)
	awaitBusy(t, idle, false)
	idle.title = "rest"

	closed := false
	h.app.confirmProcessExit(p, exitContextCloseWorkspace, func() { closed = true })
	h.await("the exit question", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	prompt := h.app.prompts.queue[0]
	if !strings.Contains(prompt.text, "Terminal “build”") || strings.Contains(prompt.text, "rest") {
		t.Fatalf("exit question lists %q", prompt.text)
	}
	h.clickNamed("Cancel")
	h.settle()
	if closed {
		t.Fatal("Cancel closed the project")
	}
}
