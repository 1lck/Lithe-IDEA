package workbench

import (
	"context"
	"sync"
	"time"
)

// taskQueue hands the results of background work to the window thread. Work runs on
// its own goroutine and must not touch the App; it returns a function that applies
// its result, which the window thread runs in OnWake before the next paint. Nothing
// waits or polls: a finished task wakes the window and the queue is empty otherwise.
type taskQueue struct {
	mu      sync.Mutex
	pending []func(*App)
	running taskGroup
	// painted is set by the first paint, which asks for the wake that results posted before
	// the window opened lost (wakeForEarlyResults). The window thread alone reads and sets it.
	painted bool
}

// post queues a result and wakes the window.
func (a *App) post(apply func(*App)) {
	a.tasks.mu.Lock()
	a.tasks.pending = append(a.tasks.pending, apply)
	a.tasks.mu.Unlock()
	a.invalidator.Invalidate()
}

// wakeForEarlyResults asks for a wake when the first paint finds results queued. The window
// binds its Invalidator when it opens and drops a wake asked for before that, so a result that
// work started in New posts early (restoreBackground decodes the saved background there) would
// wait for an unrelated wake. The first paint runs once the window is bound; a result posted
// after it wakes the window itself.
func (a *App) wakeForEarlyResults() {
	if a.tasks.painted {
		return
	}
	a.tasks.painted = true
	a.tasks.mu.Lock()
	queued := len(a.tasks.pending) > 0
	a.tasks.mu.Unlock()
	if queued {
		a.invalidator.Invalidate()
	}
}

// drain applies the queued results on the window thread, then takes in the output the
// project's shell produced. It is the window's OnWake, which runs before every repaint a
// wake asks for, so output reaches the screen without a timer.
func (a *App) drain() {
	// The window drains every workbench directly, not through the callback operating wraps.
	defer a.endOperation()
	a.tasks.mu.Lock()
	pending := a.tasks.pending
	a.tasks.pending = nil
	a.tasks.mu.Unlock()
	// Each result runs as a turn of its own: an action one of them starts ends with it.
	for _, apply := range pending {
		a.within(operation{}, apply)
	}
	a.drainSettings()
	a.pumpTerminal()
}

// background runs work on its own goroutine and applies the function it returns on the
// window thread. When p is not nil the work belongs to that project: its context ends
// when the project closes, and a result that arrives after the project was closed or
// replaced is dropped. timeout bounds the work; zero leaves it unbounded, for work the
// user ends, such as a folder dialog.
//
// work returns nil when there is nothing to apply. Work started during a user action belongs to
// it (operation.go): its context carries the action, and its result is applied under it.
// When timeout is positive, the caller can use the returned function to cancel the work sooner.
func (a *App) background(p *project, timeout time.Duration, work func(ctx context.Context) func(*App)) context.CancelFunc {
	parent := context.Background()
	if p != nil {
		parent = p.ctx
	}
	op := a.op
	parent = a.operationContext(parent)
	ctx, cancel := parent, context.CancelFunc(func() {})
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(parent, timeout)
	}
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		defer cancel()
		apply := work(ctx)
		if apply == nil {
			return
		}
		a.post(func(a *App) {
			if p != nil && a.project != p {
				return
			}
			a.within(op, apply)
		})
	}()
	return cancel
}

// wait blocks until every background task has returned, for shutdown and tests. The
// results they posted stay queued until the next drain.
func (a *App) wait() {
	a.tasks.running.Wait()
}
