package workbench

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// debugTransportKernel is the part of Core that holds the byte-stream lifecycle
// rules. Core never opens a socket or reads a clock; this file is the platform
// side that runs the effects it returns.
type debugTransportKernel interface {
	DebugTransportHandle(ctx context.Context, transportID string, event core.DebugTransportEvent) (core.DebugTransportStep, error)
	DebugTransportRelease(ctx context.Context, transportID string) error
}

// Transport errors a Write can return. The lifecycle outcome, not a local
// counter, decides which one.
var (
	errDebugTransportNotRunning = errors.New("the debug adapter stream is not running")
	errDebugTransportBuffer     = errors.New("the debug adapter stream's write queue is over its budget")
)

// debugTransportHooks are the owner's side of one stream.
type debugTransportHooks struct {
	// Discover resolves the endpoint, for example by asking a language server.
	Discover func(ctx context.Context) (host string, port int, err error)
	// Dial opens the socket; nil dials TCP.
	Dial func(ctx context.Context, host string, port int) (net.Conn, error)
	// Deliver receives bytes the adapter sent, in order.
	Deliver func(data []byte)
	// Failure reports why Core failed the stream; Message is only set for the
	// "host" reason, where it is the host's own upstream diagnostic.
	Failure func(reason, message string)
	// Terminated ends the owner's session: 0 for a clean peer close, 1 after a
	// failure. It follows Failure.
	Terminated func(exitCode int)
}

// debugTransport drives one IDE-to-adapter byte stream by Core's lifecycle
// rules: queued frames, one write in flight, connect/discovery/write deadlines
// as timers Core arms, and a bounded drain on a user stop. All state changes
// go through Core's step; the host only keeps the socket, the timers and the
// frames, and reports each result with the generation it captured.
type debugTransport struct {
	kernel debugTransportKernel
	id     string
	hooks  debugTransportHooks

	// wait bounds discovery and dialing; the close effect and Release cancel it.
	// Core calls use their own bounded context so a stop can still be reported
	// after the owner's session context ended.
	wait       context.Context
	cancelWait context.CancelFunc
	wg         sync.WaitGroup
	// done closes once Core reports the stream stopped.
	done     chan struct{}
	doneOnce sync.Once

	// mu serializes Core steps and guards the fields below.
	mu         sync.Mutex
	generation uint64
	queue      [][]byte
	conn       net.Conn
	timers     map[uint64]*time.Timer
	released   bool
}

// newDebugTransport returns a stream that is not started.
func newDebugTransport(kernel debugTransportKernel, id string, hooks debugTransportHooks) *debugTransport {
	wait, cancel := context.WithCancel(context.Background())
	return &debugTransport{kernel: kernel, id: id, hooks: hooks, wait: wait, cancelWait: cancel, done: make(chan struct{}), timers: make(map[uint64]*time.Timer)}
}

// Done closes once the stream has stopped, whether by a user stop after its
// drain, a failure or the peer closing.
func (t *debugTransport) Done() <-chan struct{} { return t.done }

// Start begins the lifecycle: Core arms the discovery deadline and asks for the
// endpoint. Frames written before the socket is ready are queued by Core's rule.
func (t *debugTransport) Start(limits *core.DebugTransportLimitOverrides) error {
	_, err := t.apply(core.DebugTransportEvent{Type: "start", Limits: limits}, nil, nil)
	return err
}

// Write queues one frame. It never blocks on the network: the frame is written
// when Core says so, and a stalled write fails the stream by its own deadline.
func (t *debugTransport) Write(frame []byte) (int, error) {
	if len(frame) == 0 {
		return 0, nil
	}
	size := uint64(len(frame))
	step, err := t.apply(core.DebugTransportEvent{Type: "send", Bytes: &size}, append([]byte(nil), frame...), nil)
	if err != nil {
		return 0, err
	}
	switch step.Outcome {
	case "applied":
		return len(frame), nil
	case "rejectedBufferLimit":
		return 0, errDebugTransportBuffer
	default:
		return 0, errDebugTransportNotRunning
	}
}

// Close is a user cancel: silent teardown, no termination callback.
func (t *debugTransport) Close() error {
	_, err := t.apply(core.DebugTransportEvent{Type: "stop"}, nil, nil)
	return err
}

// FinishSendingAndStop flushes queued frames of a ready stream for at most the
// drain budget, then closes silently. It is the user stop of a live session, so
// the DAP disconnect already queued still reaches the adapter.
func (t *debugTransport) FinishSendingAndStop() error {
	_, err := t.apply(core.DebugTransportEvent{Type: "finishSendingAndStop"}, nil, nil)
	return err
}

// Release drops every host handle and forgets Core's registration. Call it once
// the stream is stopped; later callbacks are rejected before they touch Core.
func (t *debugTransport) Release() {
	t.mu.Lock()
	if t.released {
		t.mu.Unlock()
		return
	}
	t.released = true
	t.dropHandlesLocked()
	t.mu.Unlock()
	t.wg.Wait()
	ctx, cancel := context.WithTimeout(context.Background(), debugStopTimeout)
	defer cancel()
	_ = t.kernel.DebugTransportRelease(ctx, t.id)
}

// dropHandlesLocked closes the socket, cancels waits and timers and drops
// queued frames.
func (t *debugTransport) dropHandlesLocked() {
	t.cancelWait()
	t.wait, t.cancelWait = context.WithCancel(context.Background())
	if t.conn != nil {
		_ = t.conn.Close()
		t.conn = nil
	}
	for id, timer := range t.timers {
		timer.Stop()
		delete(t.timers, id)
	}
	t.queue = nil
}

// apply feeds one event to Core and runs the effects it answers with. frame is
// queued before the step so a write effect finds it; data is the chunk a
// dataReceived event stands for.
func (t *debugTransport) apply(event core.DebugTransportEvent, frame, data []byte) (core.DebugTransportStep, error) {
	t.mu.Lock()
	if t.released {
		t.mu.Unlock()
		return core.DebugTransportStep{Outcome: "ignored"}, nil
	}
	if frame != nil {
		t.queue = append(t.queue, frame)
	}
	callCtx, cancelCall := context.WithTimeout(context.Background(), debugOperationTimeout)
	step, err := t.kernel.DebugTransportHandle(callCtx, t.id, event)
	cancelCall()
	if err != nil {
		if frame != nil {
			t.queue = t.queue[:len(t.queue)-1]
		}
		// A Core failure must still tear the native resources down.
		t.dropHandlesLocked()
		t.mu.Unlock()
		return core.DebugTransportStep{}, err
	}
	if frame != nil && step.Outcome != "applied" {
		t.queue = t.queue[:len(t.queue)-1]
	}
	t.generation = step.Generation
	if step.Phase == "stopped" {
		t.doneOnce.Do(func() { close(t.done) })
	}
	var owner []func()
	t.runLocked(step, data, &owner)
	t.mu.Unlock()
	for _, call := range owner {
		// An observer that restarts the stream bumps the generation; the rest of
		// this older step is abandoned.
		t.mu.Lock()
		stale := t.generation != step.Generation
		t.mu.Unlock()
		if stale {
			break
		}
		call()
	}
	return step, nil
}

// runLocked runs one step's effects top to bottom. Blocking work goes to
// goroutines that report back with the generation captured here; calls into the
// owner are collected so they run after the lock is released.
func (t *debugTransport) runLocked(step core.DebugTransportStep, data []byte, owner *[]func()) {
	generation := step.Generation
	for _, effect := range step.Effects {
		switch effect.Kind {
		case "discoverEndpoint":
			wait := t.wait
			t.spawn(func() { t.discover(wait, generation) })
		case "armTimer":
			timerID := effect.TimerID
			t.timers[timerID] = time.AfterFunc(time.Duration(effect.AfterMilliseconds)*time.Millisecond, func() {
				t.timerFired(generation, timerID)
			})
		case "cancelTimer":
			if timer := t.timers[effect.TimerID]; timer != nil {
				timer.Stop()
				delete(t.timers, effect.TimerID)
			}
		case "connect":
			host, port := effect.Host, effect.Port
			wait := t.wait
			t.spawn(func() { t.connect(wait, generation, host, port) })
		case "write":
			if len(t.queue) == 0 {
				continue
			}
			frame := t.queue[0]
			t.queue = t.queue[1:]
			conn, writeID := t.conn, effect.WriteID
			t.spawn(func() { t.writeFrame(generation, writeID, conn, frame) })
		case "deliverData":
			if len(data) > 0 && t.hooks.Deliver != nil {
				chunk := data
				*owner = append(*owner, func() { t.hooks.Deliver(chunk) })
			}
		case "close":
			t.dropHandlesLocked()
		case "reportFailure":
			reason, message := effect.Reason, effect.Message
			if t.hooks.Failure != nil {
				*owner = append(*owner, func() { t.hooks.Failure(reason, message) })
			}
		case "notifyTermination":
			code := effect.ExitCode
			if t.hooks.Terminated != nil {
				*owner = append(*owner, func() { t.hooks.Terminated(code) })
			}
		}
	}
}

// spawn runs blocking work under the wait group; apply refuses new work once
// the stream is released, so Release's Wait cannot race an Add.
func (t *debugTransport) spawn(work func()) {
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		work()
	}()
}

func (t *debugTransport) timerFired(generation, timerID uint64) {
	_, _ = t.apply(core.DebugTransportEvent{Type: "timerFired", Generation: &generation, TimerID: &timerID}, nil, nil)
}

func (t *debugTransport) failed(generation uint64, err error) {
	message := err.Error()
	_, _ = t.apply(core.DebugTransportEvent{Type: "failed", Generation: &generation, Message: &message}, nil, nil)
}

func (t *debugTransport) discover(wait context.Context, generation uint64) {
	host, port, err := t.hooks.Discover(wait)
	if wait.Err() != nil {
		return
	}
	if err != nil {
		t.failed(generation, err)
		return
	}
	wide := int64(port)
	_, _ = t.apply(core.DebugTransportEvent{Type: "endpointResolved", Generation: &generation, Host: &host, Port: &wide}, nil, nil)
}

func (t *debugTransport) connect(wait context.Context, generation uint64, host string, port int) {
	dial := t.hooks.Dial
	if dial == nil {
		dial = func(ctx context.Context, host string, port int) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		}
	}
	conn, err := dial(wait, host, port)
	if wait.Err() != nil {
		if conn != nil {
			_ = conn.Close()
		}
		return
	}
	if err != nil {
		t.failed(generation, err)
		return
	}
	t.mu.Lock()
	if t.released || t.generation != generation {
		// The attempt was invalidated while dialing: drop the socket unseen.
		t.mu.Unlock()
		_ = conn.Close()
		return
	}
	t.conn = conn
	t.mu.Unlock()
	if _, err := t.apply(core.DebugTransportEvent{Type: "connectionReady", Generation: &generation}, nil, nil); err != nil {
		return
	}
	t.read(generation, conn)
}

// read reports every chunk to Core and forwards it only when Core says so.
func (t *debugTransport) read(generation uint64, conn net.Conn) {
	buffer := make([]byte, debugReadChunk)
	for {
		count, err := conn.Read(buffer)
		if count > 0 {
			chunk := append([]byte(nil), buffer[:count]...)
			_, _ = t.apply(core.DebugTransportEvent{Type: "dataReceived", Generation: &generation}, nil, chunk)
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			_, _ = t.apply(core.DebugTransportEvent{Type: "peerClosed", Generation: &generation}, nil, nil)
		} else {
			t.failed(generation, err)
		}
		return
	}
}

func (t *debugTransport) writeFrame(generation, writeID uint64, conn net.Conn, frame []byte) {
	if conn == nil {
		t.failed(generation, errDebugTransportNotRunning)
		return
	}
	if _, err := conn.Write(frame); err != nil {
		t.failed(generation, err)
		return
	}
	_, _ = t.apply(core.DebugTransportEvent{Type: "writeCompleted", Generation: &generation, WriteID: &writeID}, nil, nil)
}
