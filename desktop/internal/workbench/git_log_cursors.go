package workbench

import (
	"context"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A read owns its returned cursors until the window accepts its result or cleanup claims them.
// Project close can claim a completed read even after the window has stopped draining results.
type logCursorReads struct {
	running taskGroup
	mu      sync.Mutex
	pending map[*logCursorRead][]logCursor
	retired bool
	drained bool
}

type logCursorRead struct {
	owner context.Context
}

type logReadResult struct {
	cursors []logCursor
	// publish returns whether the result transferred its cursors to the window.
	publish func(*App) bool
}

func logPageCursor(root, cursor string) []logCursor {
	if cursor == "" {
		return nil
	}
	return []logCursor{{root, cursor}}
}

func (a *App) backgroundLogRead(p *project, work func(context.Context) logReadResult) context.CancelFunc {
	reads := &p.logReads
	owner := a.operationContext(core.SnapshotRemoteWorkspace(p.ctx))
	session := logRemoteSession(owner)
	ctx, cancel := context.WithTimeout(owner, gitTimeout)
	read := &logCursorRead{owner: owner}
	kernel := a.kernel
	reads.running.Add(1)
	a.background(nil, 0, func(context.Context) func(*App) {
		defer reads.running.Done()
		defer cancel()
		result := work(ctx)
		if !reads.store(read, result.cursors) {
			ctx, release := context.WithTimeout(context.WithoutCancel(owner), remoteLogCloseTimeout)
			defer release()
			a.closeLogCursors(ctx, kernel, result.cursors)
			return nil
		}
		return func(a *App) {
			if reads.retired {
				return
			}
			cursors := reads.take(read)
			if session != logRemoteSession(p.ctx) || !result.publish(a) {
				a.queueLogCursorClose(p, owner, cursors)
			} else if len(cursors) != 0 {
				p.log.cursorOwner = owner
			}
		}
	})
	return cancel
}

func logRemoteSession(ctx context.Context) string {
	if binding := core.RemoteWorkspaceOf(ctx); binding != nil {
		return binding.SessionID()
	}
	return ""
}

func (reads *logCursorReads) store(read *logCursorRead, cursors []logCursor) bool {
	reads.mu.Lock()
	defer reads.mu.Unlock()
	if reads.drained {
		return false
	}
	if len(cursors) != 0 {
		if reads.pending == nil {
			reads.pending = make(map[*logCursorRead][]logCursor)
		}
		reads.pending[read] = cursors
	}
	return true
}

func (reads *logCursorReads) take(read *logCursorRead) []logCursor {
	reads.mu.Lock()
	defer reads.mu.Unlock()
	cursors := reads.pending[read]
	delete(reads.pending, read)
	return cursors
}

func (reads *logCursorReads) takeForClose() map[*logCursorRead][]logCursor {
	reads.mu.Lock()
	defer reads.mu.Unlock()
	pending := reads.pending
	reads.pending = nil
	reads.drained = true
	return pending
}

func (a *App) queueLogCursorClose(p *project, owner context.Context, cursors []logCursor) {
	if len(cursors) == 0 {
		return
	}
	kernel := a.kernel
	reads := &p.logReads
	reads.running.Add(1)
	a.background(nil, 0, func(context.Context) func(*App) {
		defer reads.running.Done()
		ctx, cancel := context.WithTimeout(context.WithoutCancel(owner), remoteLogCloseTimeout)
		defer cancel()
		a.closeLogCursors(ctx, kernel, cursors)
		return nil
	})
}
