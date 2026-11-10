package workbench

import (
	"testing"
	"time"
)

// TestClosingWithARunningDebugSessionAsksFirst: a close while Lithe's own
// debug session runs is a question; cancelling keeps the project and its
// session, and stopping closes both.
func TestClosingWithARunningDebugSessionAsksFirst(t *testing.T) {
	h, p := pausedDebugSession(t)
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	awaitStateWithin(t, h, 20*time.Second, "the exit question", func() bool { return len(h.app.prompts.queue) == 1 })
	_ = h.app.prompts.queue[0]
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
