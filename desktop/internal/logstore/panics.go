package logstore

import (
	"slices"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// panicLimit bounds the recovered panics one drain writes; the rest are counted as dropped.
const panicLimit = 8

// panicQueue holds recovered panics until the writer's next drain. A panic is recovered on
// whatever thread raised it, often inside a callback of AppKit, Win32 or the kernel that holds
// its own lock, so recording one may neither block nor take a lock: the queue is a lock-free
// stack the drain empties at once. It is filled even while the store is stopping, which is why
// it does not go through Emit, and the final drain still writes it.
type panicQueue struct {
	now   func() time.Time
	head  atomic.Pointer[panicNode]
	count atomic.Int64
	lost  atomic.Uint64
}

type panicNode struct {
	event queued
	next  *panicNode
}

// Emit queues one event, or counts it as lost while panicLimit events are already waiting.
func (q *panicQueue) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	if q.count.Add(1) > panicLimit {
		q.count.Add(-1)
		q.lost.Add(1)
		return
	}
	node := &panicNode{event: queued{ts: q.now(), level: level, event: event, op: op, fields: fields}}
	for {
		node.next = q.head.Load()
		if q.head.CompareAndSwap(node.next, node) {
			return
		}
	}
}

// take empties the queue and returns its events oldest first, with the number lost since the
// previous take.
func (q *panicQueue) take() ([]queued, uint64) {
	var events []queued
	for node := q.head.Swap(nil); node != nil; node = node.next {
		events = append(events, node.event)
	}
	q.count.Add(-int64(len(events)))
	slices.Reverse(events)
	return events, q.lost.Swap(0)
}

// RecordPanic logs a panic recovered at boundary, such as viva:window-procedure or
// core:events-observer, as app.runtime.panic_interrupted: value is the panic value as text and
// stack the panicking goroutine's stack as runtime/debug.Stack prints it, nil when there is
// none. It may be called from any thread, including inside a platform or kernel callback that
// holds a lock: it neither blocks, nor takes a lock, nor calls the kernel. The record reaches
// the disk with the writer's next drain, which it schedules, and also when Close is already
// running; a panic recorded after Close has returned is not written.
func (s *Store) RecordPanic(boundary, value string, stack []byte) {
	fields := map[string]any{"boundary": core.LogToken(boundary), "panic": core.LogText(value)}
	if fields["panic"] == "" {
		fields["panic"] = "<empty>"
	}
	if frames := core.LogPanicStack(stack); frames != "" {
		fields["stack"] = frames
	}
	s.panics.Emit(core.LevelError, "app.runtime.panic_interrupted", "", fields)
	signal(s.wake)
}
