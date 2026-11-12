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
	running sync.WaitGroup
}

// post queues a result and wakes the window.
func (a *App) post(apply func(*App)) {
	a.tasks.mu.Lock()
	a.tasks.pending = append(a.tasks.pending, apply)
	a.tasks.mu.Unlock()
	a.invalidator.Invalidate()
}

// drain applies the queued results on the window thread, then takes in the output the
// project's shell produced. It is the window's OnWake, which runs before every repaint a
// wake asks for, so output reaches the screen without a timer.
func (a *App) drain() {
	a.tasks.mu.Lock()
	pending := a.tasks.pending
	a.tasks.pending = nil
	a.tasks.mu.Unlock()
	for _, apply := range pending {
		apply(a)
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
// work returns nil when there is nothing to apply.
func (a *App) background(p *project, timeout time.Duration, work func(ctx context.Context) func(*App)) {
	parent := context.Background()
	if p != nil {
		parent = p.ctx
	}
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
			apply(a)
		})
	}()
}

// wait blocks until every background task has returned, for shutdown and tests. The
// results they posted stay queued until the next drain.
func (a *App) wait() {
	a.tasks.running.Wait()
}
