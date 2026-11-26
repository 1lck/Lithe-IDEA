package workbench

import (
	"context"
	"sync"
)

// taskGroup tracks one batch of background work. Each nonempty batch owns an
// idle channel, so cancelled waits need no helper goroutine and a new batch
// cannot hide the previous batch's completion from an existing waiter.
type taskGroup struct {
	mu    sync.Mutex
	count int
	idle  chan struct{}
}

func (g *taskGroup) Add(delta int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	count := g.count + delta
	if count < 0 {
		panic("workbench: negative task count")
	}
	if g.count == 0 && count > 0 {
		g.idle = make(chan struct{})
	}
	if g.count > 0 && count == 0 {
		close(g.idle)
	}
	g.count = count
}

func (g *taskGroup) Done() { g.Add(-1) }

func (g *taskGroup) Count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.count
}

func (g *taskGroup) Wait() {
	g.mu.Lock()
	if g.count == 0 {
		g.mu.Unlock()
		return
	}
	idle := g.idle
	g.mu.Unlock()
	<-idle
}

// WaitContext waits for the batch active when called. Completion wins over
// cancellation when both are observable; cancelling a wait never cancels work.
func (g *taskGroup) WaitContext(ctx context.Context) error {
	g.mu.Lock()
	if g.count == 0 {
		g.mu.Unlock()
		return nil
	}
	idle := g.idle
	g.mu.Unlock()
	select {
	case <-idle:
		return nil
	case <-ctx.Done():
		select {
		case <-idle:
			return nil
		default:
			return ctx.Err()
		}
	}
}
