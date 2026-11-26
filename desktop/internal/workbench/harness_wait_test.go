package workbench

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestLogReferenceSelectionDoesNotWaitForUnrelatedTask(t *testing.T) {
	h, p, _ := localBranchDeleteFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	started, ended := make(chan struct{}), make(chan struct{})
	gate := make(chan struct{})
	h.app.background(p, 0, func(context.Context) func(*App) {
		close(started)
		defer close(ended)
		select {
		case <-gate:
		case <-ctx.Done():
		}
		return nil
	})
	t.Cleanup(func() {
		close(gate)
		awaitTaskGroupSignal(t, ended, "unrelated task cleanup")
	})
	awaitTaskGroupSignal(t, started, "unrelated task start")
	h.clickLogRef("main")
	if ctx.Err() != nil {
		t.Fatal("selecting a reference waited for an unrelated task's deadline")
	}
	if p.log.refSelected != "refs/heads/main" {
		t.Fatalf("selected reference = %q, want refs/heads/main", p.log.refSelected)
	}
	select {
	case <-ended:
		t.Fatal("the unrelated task ended before its explicit release")
	default:
	}
}

func TestHarnessPredicateWaitFollowsMoreThanTwelveTurns(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	turns := 0
	var next func(*App)
	next = func(a *App) {
		turns++
		if turns < 20 {
			a.background(nil, time.Second, func(context.Context) func(*App) { return next })
		}
	}
	h.app.post(next)
	h.settleUntil("twenty completed background turns", func() bool { return turns == 20 })
}
