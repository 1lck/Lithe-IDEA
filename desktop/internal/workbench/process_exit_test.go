package workbench

import (
	"strings"
	"testing"
	"time"
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
