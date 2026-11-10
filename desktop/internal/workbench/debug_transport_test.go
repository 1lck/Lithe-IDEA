package workbench

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// transportRecorder collects what the stream tells its owner.
type transportRecorder struct {
	data       chan []byte
	failures   chan [2]string
	terminated chan int
}

func newTransportRecorder() *transportRecorder {
	return &transportRecorder{data: make(chan []byte, 16), failures: make(chan [2]string, 4), terminated: make(chan int, 4)}
}

func (r *transportRecorder) hooks(discover func(context.Context) (string, int, error)) debugTransportHooks {
	return debugTransportHooks{
		Discover:   discover,
		Deliver:    func(data []byte) { r.data <- data },
		Failure:    func(reason, message string) { r.failures <- [2]string{reason, message} },
		Terminated: func(code int) { r.terminated <- code },
	}
}

func loopbackListener(t *testing.T) (net.Listener, func(context.Context) (string, int, error)) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	port := listener.Addr().(*net.TCPAddr).Port
	return listener, func(context.Context) (string, int, error) { return "127.0.0.1", port, nil }
}

func waitFor[T any](t *testing.T, channel <-chan T, what string) T {
	t.Helper()
	select {
	case value := <-channel:
		return value
	case <-time.After(10 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
		panic("unreachable")
	}
}

// TestDebugTransportQueuesFramesBeforeReadyAndKeepsOrder drives the stream by
// Core's lifecycle: frames written during discovery arrive in order once the
// socket is connected, and bytes the peer sends are delivered to the owner.
func TestDebugTransportQueuesFramesBeforeReadyAndKeepsOrder(t *testing.T) {
	listener, discover := loopbackListener(t)
	release := make(chan struct{})
	recorder := newTransportRecorder()
	transport := newDebugTransport(core.NewClient(), "test-queue-order", recorder.hooks(func(ctx context.Context) (string, int, error) {
		<-release
		return discover(ctx)
	}))
	defer transport.Release()
	if err := transport.Start(nil); err != nil {
		t.Fatal(err)
	}
	for _, frame := range []string{"one;", "two;", "three;"} {
		if _, err := transport.Write([]byte(frame)); err != nil {
			t.Fatalf("write %q: %v", frame, err)
		}
	}
	close(release)
	connection, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	got := make([]byte, len("one;two;three;"))
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(connection, got); err != nil || !bytes.Equal(got, []byte("one;two;three;")) {
		t.Fatalf("peer received %q, %v", got, err)
	}
	if _, err := connection.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	if data := waitFor(t, recorder.data, "delivered data"); string(data) != "hello" {
		t.Fatalf("delivered %q", data)
	}
	_ = connection.Close()
	if code := waitFor(t, recorder.terminated, "termination"); code != 0 {
		t.Fatalf("a clean peer close terminated with %d, want 0", code)
	}
}

// TestDebugTransportBufferBudgetFailsTheStream proves the queue budget is
// Core's: the write over it is rejected and the stream fails and terminates.
func TestDebugTransportBufferBudgetFailsTheStream(t *testing.T) {
	recorder := newTransportRecorder()
	transport := newDebugTransport(core.NewClient(), "test-buffer-budget", recorder.hooks(func(ctx context.Context) (string, int, error) {
		<-ctx.Done()
		return "", 0, ctx.Err()
	}))
	defer transport.Release()
	one := 1
	if err := transport.Start(&core.DebugTransportLimitOverrides{BufferedWrites: &one}); err != nil {
		t.Fatal(err)
	}
	if _, err := transport.Write([]byte("a")); err != nil {
		t.Fatal(err)
	}
	if _, err := transport.Write([]byte("b")); !errors.Is(err, errDebugTransportBuffer) {
		t.Fatalf("second write = %v, want the buffer budget", err)
	}
	if failure := waitFor(t, recorder.failures, "failure"); failure[0] != "bufferLimit" {
		t.Fatalf("failure = %v", failure)
	}
	if code := waitFor(t, recorder.terminated, "termination"); code != 1 {
		t.Fatalf("termination = %d, want 1", code)
	}
	if _, err := transport.Write([]byte("c")); !errors.Is(err, errDebugTransportNotRunning) {
		t.Fatalf("write after failure = %v, want not running", err)
	}
}

// TestDebugTransportDiscoveryDeadlineIsCoresTimer shows the deadline belongs to
// Core: a discovery that never answers fails by the timer Core armed.
func TestDebugTransportDiscoveryDeadlineIsCoresTimer(t *testing.T) {
	recorder := newTransportRecorder()
	transport := newDebugTransport(core.NewClient(), "test-discovery-deadline", recorder.hooks(func(ctx context.Context) (string, int, error) {
		<-ctx.Done()
		return "", 0, ctx.Err()
	}))
	defer transport.Release()
	short := 50
	if err := transport.Start(&core.DebugTransportLimitOverrides{DiscoveryMilliseconds: &short}); err != nil {
		t.Fatal(err)
	}
	if failure := waitFor(t, recorder.failures, "failure"); failure[0] != "startupTimedOut" {
		t.Fatalf("failure = %v, want startupTimedOut", failure)
	}
	if code := waitFor(t, recorder.terminated, "termination"); code != 1 {
		t.Fatalf("termination = %d", code)
	}
}

// TestDebugTransportUserStopDrainsQueuedFramesThenClosesSilently is the user
// stop of a live session: the disconnect frame still reaches the peer, then the
// socket closes with no termination callback.
func TestDebugTransportUserStopDrainsQueuedFramesThenClosesSilently(t *testing.T) {
	listener, discover := loopbackListener(t)
	recorder := newTransportRecorder()
	transport := newDebugTransport(core.NewClient(), "test-user-stop", recorder.hooks(discover))
	defer transport.Release()
	if err := transport.Start(nil); err != nil {
		t.Fatal(err)
	}
	connection, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if _, err := transport.Write([]byte("disconnect")); err != nil {
		t.Fatal(err)
	}
	if err := transport.FinishSendingAndStop(); err != nil {
		t.Fatal(err)
	}
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	all, err := io.ReadAll(connection)
	if err != nil || string(all) != "disconnect" {
		t.Fatalf("peer received %q, %v", all, err)
	}
	waitFor(t, transport.Done(), "the stream to stop")
	select {
	case code := <-recorder.terminated:
		t.Fatalf("a user stop terminated the owner with %d", code)
	default:
	}
}
