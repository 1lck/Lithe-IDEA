package core

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"unsafe"
)

var (
	// ErrAgentClosed reports that the Core-owned agent connection has been closed.
	ErrAgentClosed = errors.New("agent connection is closed")
	// ErrAgentEventOverflow means events were lost; the caller must close and
	// discard this connection rather than present an incomplete conversation.
	ErrAgentEventOverflow = errors.New("agent event queue exceeded its limit")
	// ErrAgentCommandRejected means Core did not accept a command for this connection.
	ErrAgentCommandRejected = errors.New("agent command was not accepted")
	// ErrAgentOpen means Core could not create the connection handle.
	ErrAgentOpen = errors.New("agent connection could not be opened")
)

const (
	agentEventCountLimit  = 256
	agentEventBytesLimit  = 16 << 20
	agentEventSingleLimit = 4 << 20
)

// agentEventQueue keeps callbacks short and bounded: Rust holds its callback
// lock while calling Go, so the callback must not wait on the UI or close the
// connection. An overflow invalidates the stream rather than silently losing
// an update, permission request, or terminal event.
type agentEventQueue struct {
	events     chan json.RawMessage
	overflow   chan struct{}
	bytes      atomic.Int64
	failed     atomic.Bool
	closed     atomic.Bool
	overflowMu sync.Once
}

func newAgentEventQueue() *agentEventQueue {
	return &agentEventQueue{events: make(chan json.RawMessage, agentEventCountLimit), overflow: make(chan struct{})}
}

func (q *agentEventQueue) fail() {
	q.failed.Store(true)
	q.overflowMu.Do(func() { close(q.overflow) })
}

func (q *agentEventQueue) reserve(size int) bool {
	if q.failed.Load() || q.closed.Load() {
		return false
	}
	if size < 0 || size > agentEventSingleLimit {
		q.fail()
		return false
	}
	if q.bytes.Add(int64(size)) > agentEventBytesLimit {
		q.bytes.Add(-int64(size))
		q.fail()
		return false
	}
	return true
}

func (q *agentEventQueue) publish(event json.RawMessage) {
	select {
	case q.events <- event:
	default:
		q.bytes.Add(-int64(len(event)))
		q.fail()
	}
}

// AgentSession is one Core-owned ACP connection. It is safe to send and close
// concurrently; the native handle is never called while close is running.
// Close is bounded by Core's subprocess shutdown and must run off the UI thread.
type AgentSession struct {
	mu     sync.Mutex
	handle unsafe.Pointer
	id     uintptr
	queue  *agentEventQueue
}

// OpenAgentSession opens Core's asynchronous ACP bridge from the documented
// launch JSON. The JSON may contain credentials: callers must not log it.
// Launch failures after handle creation arrive as Core's stopped event.
func OpenAgentSession(launch json.RawMessage) (*AgentSession, error) {
	if !json.Valid(launch) {
		return nil, ErrAgentOpen
	}
	queue := newAgentEventQueue()
	id := registerAgentQueue(queue)
	handle := openNativeAgent(launch, id)
	if handle == nil {
		unregisterAgentQueue(id)
		return nil, ErrAgentOpen
	}
	return &AgentSession{handle: handle, id: id, queue: queue}, nil
}

// Send passes one documented command to Core without implementing ACP in Go.
func (s *AgentSession) Send(command json.RawMessage) error {
	if !json.Valid(command) {
		return ErrAgentCommandRejected
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.handle == nil {
		return ErrAgentClosed
	}
	if s.queue.failed.Load() {
		return ErrAgentEventOverflow
	}
	if !sendNativeAgent(s.handle, command) {
		return ErrAgentCommandRejected
	}
	return nil
}

// Next waits for one Core event or the caller's cancellation. After an
// overflow, callers must close the session and treat its state as incomplete.
func (s *AgentSession) Next(ctx context.Context) (json.RawMessage, error) {
	q := s.queue
	if q.failed.Load() {
		return nil, ErrAgentEventOverflow
	}
	if q.closed.Load() {
		return nil, ErrAgentClosed
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-q.overflow:
		return nil, ErrAgentEventOverflow
	case event, ok := <-q.events:
		if !ok {
			return nil, ErrAgentClosed
		}
		q.bytes.Add(-int64(len(event)))
		if q.failed.Load() {
			return nil, ErrAgentEventOverflow
		}
		if q.closed.Load() {
			return nil, ErrAgentClosed
		}
		return event, nil
	}
}

// Close revokes native callbacks before releasing their registry entry. It is
// idempotent and may wait for Core to stop and reap the child process tree.
func (s *AgentSession) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.handle == nil {
		return
	}
	s.queue.closed.Store(true)
	closeNativeAgent(s.handle)
	s.handle = nil
	unregisterAgentQueue(s.id)
	close(s.queue.events)
	for event := range s.queue.events {
		s.queue.bytes.Add(-int64(len(event)))
	}
}
