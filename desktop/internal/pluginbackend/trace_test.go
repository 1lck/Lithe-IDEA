package pluginbackend

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// traceCall is one trace switch a session received.
type traceCall struct {
	session string
	enabled bool
}

// traceWait bounds how long a test waits for a switch the runner sends on its own goroutine.
const traceWait = 10 * time.Second

func nextTrace(t *testing.T, calls <-chan traceCall) traceCall {
	t.Helper()
	select {
	case call := <-calls:
		return call
	case <-time.After(traceWait):
		t.Fatal("no trace switch reached a session")
		return traceCall{}
	}
}

// settled waits until the runner has finished telling its sessions, so a test can then check
// that nothing more was sent.
func settled(r *Runner) {
	r.trace.send.Lock()
	defer r.trace.send.Unlock()
}

// TestDetailedDiagnosticsReachRunningAndNewSessions checks that turning detailed diagnostics
// on switches the trace of the sessions already running, that a session started while they are
// on is switched on as it starts, that choosing the same value again sends nothing, and that a
// session that was stopped or has ended is not told any more.
func TestDetailedDiagnosticsReachRunningAndNewSessions(t *testing.T) {
	root := backendPackage(t)
	kernel := &fakeKernel{plan: packagedPlan(), started: core.PluginBackendStarted{SessionID: "session-1"}, traces: make(chan traceCall, 8)}
	runner := New(kernel, echoServices(t))

	first, err := runner.Start(context.Background(), startRequest(root))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if len(kernel.traces) != 0 {
		t.Fatalf("a session started with diagnostics off was sent %+v", <-kernel.traces)
	}

	runner.SetDetailedDiagnostics(true)
	if got := nextTrace(t, kernel.traces); got != (traceCall{session: "session-1", enabled: true}) {
		t.Fatalf("the running session got %+v, want its trace switched on", got)
	}
	settled(runner)

	kernel.started = core.PluginBackendStarted{SessionID: "session-2"}
	second, err := runner.Start(context.Background(), startRequest(root))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if len(kernel.traces) != 1 {
		t.Fatalf("a session started with diagnostics on got %d switches, want one as it starts", len(kernel.traces))
	}
	if got := <-kernel.traces; got != (traceCall{session: "session-2", enabled: true}) {
		t.Fatalf("the new session got %+v, want its trace switched on", got)
	}

	runner.SetDetailedDiagnostics(true)
	settled(runner)
	if len(kernel.traces) != 0 {
		t.Fatalf("choosing the same value again sent %+v", <-kernel.traces)
	}

	if err := runner.Stop(context.Background(), first); err != nil {
		t.Fatalf("stop: %v", err)
	}
	runner.SetDetailedDiagnostics(false)
	if got := nextTrace(t, kernel.traces); got != (traceCall{session: "session-2", enabled: false}) {
		t.Fatalf("turning diagnostics off sent %+v, want only the running session switched off", got)
	}
	settled(runner)
	if len(kernel.traces) != 0 {
		t.Fatalf("a stopped session was still told: %+v", <-kernel.traces)
	}

	kernel.events = [][]core.BackendEvent{{{Type: EventExit}}}
	if err := runner.Serve(context.Background(), second, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}
	runner.SetDetailedDiagnostics(true)
	settled(runner)
	if len(kernel.traces) != 0 {
		t.Fatalf("a session that ended was still told: %+v", <-kernel.traces)
	}
}

// TestTraceRefusalIsReportedOncePerChoice checks that sessions refusing a switch report one
// failure for that choice, not one per session, that the next choice may report again, and
// that a session ending while it was told is not a failure.
func TestTraceRefusalIsReportedOncePerChoice(t *testing.T) {
	refused := errors.New("lithe core: lsp.setDetailedDiagnostics: refused (unknown)")
	kernel := &endingKernel{fakeKernel: fakeKernel{traces: make(chan traceCall, 8), traceRefused: map[string]error{"a": refused, "b": refused}}}
	runner := New(kernel, nil)
	kernel.runner = runner
	reports := make(chan error, 8)
	runner.SetTraceFailed(func(err error) { reports <- err })
	runner.trackTrace("a")
	runner.trackTrace("b")

	runner.SetDetailedDiagnostics(true)
	nextTrace(t, kernel.traces)
	nextTrace(t, kernel.traces)
	settled(runner)
	if len(reports) != 1 {
		t.Fatalf("two refusals of one choice reported %d failures, want one", len(reports))
	}
	if err := <-reports; !errors.Is(err, refused) {
		t.Fatalf("reported %v, want the session's refusal", err)
	}

	runner.SetDetailedDiagnostics(false)
	nextTrace(t, kernel.traces)
	nextTrace(t, kernel.traces)
	settled(runner)
	if len(reports) != 1 {
		t.Fatalf("the next choice reported %d failures, want one again", len(reports))
	}
	<-reports

	runner.untrackTrace("a")
	runner.untrackTrace("b")
	kernel.ending = "c"
	kernel.traceRefused["c"] = refused
	runner.trackTrace("c")
	runner.SetDetailedDiagnostics(true)
	nextTrace(t, kernel.traces)
	settled(runner)
	if len(reports) != 0 {
		t.Fatalf("a session that ended while it was told reported %v", <-reports)
	}
}

// endingKernel ends the session named ending while it is being told, the way a session that
// exits at that moment is refused by Core.
type endingKernel struct {
	fakeKernel
	runner *Runner
	ending string
}

func (k *endingKernel) SetDetailedDiagnostics(ctx context.Context, session string, enabled bool) error {
	if session == k.ending {
		k.runner.untrackTrace(session)
	}
	return k.fakeKernel.SetDetailedDiagnostics(ctx, session, enabled)
}
