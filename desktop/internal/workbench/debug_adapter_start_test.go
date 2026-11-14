package workbench

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	debugFixturePluginID = "dev.lithe.test.debug-adapter"
	debugHostedPluginID  = "dev.lithe.test.debug-hosted"
)

// wantDebugStart checks a recorded adapter start of session against outcome and stage.
func wantDebugStart(t *testing.T, got core.PluginOperation, pluginID string, session *debugSession, outcome string, stage core.PluginStage) {
	t.Helper()
	wantPluginOperation(t, got, core.PluginOperation{PluginID: pluginID, Operation: core.OperationDebugAdapterStart, Outcome: outcome, Stage: stage, OperationID: session.id})
}

// awaitDebugSessionDone waits until nothing of session can still record: its startup returned
// and, when it started a process, the process's watcher did.
func awaitDebugSessionDone(t *testing.T, session *debugSession) {
	t.Helper()
	select {
	case <-session.startupDone:
	case <-time.After(debugAdapterExitWait):
		t.Fatal("the debug startup did not finish before the deadline")
	}
	if session.process.Load() == nil {
		return
	}
	select {
	case <-session.exitObserved:
	case <-time.After(debugAdapterExitWait):
		t.Fatal("the adapter process was not observed to exit before the deadline")
	}
}

func writeDebugMarker(t *testing.T, root, mode string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte(mode), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDebugAdapterStartIsRecordedWhenTheAdapterAnswersInitialize(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugFixturePluginID, debugFixtureManifest, true, plugins)
	root := t.TempDir()
	writeDebugMarker(t, root, "debug")
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "the paused session", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused"
	})
	wantDebugStart(t, plugins.next(t, "the adapter start"), debugFixturePluginID, session, "finished", "")

	// The session's later work and its stop are not the start: nothing more is recorded.
	h.app.stopDebug(p)
	awaitStateWithin(t, h, debugAdapterExitWait, "the stopped session", func() bool { return p.debug.activeSession() == nil })
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

func TestDebugAdapterThatExitsBeforeInitializeIsRecordedAsAnExit(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugFixturePluginID, debugFixtureManifest, true, plugins)
	root := t.TempDir()
	writeDebugMarker(t, root, "exit")
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "adapter exit to release session", func() bool { return p.debug.activeSession() == nil })
	// The exit is recorded once, whether the process watcher or the refused initialize write
	// sees it first.
	wantDebugStart(t, plugins.next(t, "the adapter exit"), debugFixturePluginID, session, "failed", core.StageExit)
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

func TestDebugAdapterWhoseProgramIsMissingIsRecordedAsUnresolved(t *testing.T) {
	plugins := newRecordingPluginKernel()
	manifest := strings.Replace(debugFixtureManifest, `"path": "adapter"`, `"path": "absent-adapter"`, 1)
	h := debugPluginHarnessOn(t, debugFixturePluginID, manifest, true, plugins)
	root := t.TempDir()
	writeDebugMarker(t, root, "debug")
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "the failed start", func() bool { return p.debug.failure != "" })
	wantDebugStart(t, plugins.next(t, "the unresolved adapter"), debugFixturePluginID, session, "failed", core.StageResolve)
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

func TestDebugAdapterStartTheUserStopsIsNotRecorded(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugFixturePluginID, debugFixtureManifest, true, plugins)
	root := t.TempDir()
	writeDebugMarker(t, root, "debug")
	p := openDebugPanel(t, h, root)
	// The adapter runs but is sent nothing while Core creates the session, so Stop comes before
	// the adapter can answer.
	gate := &delayedDebugCreate{Kernel: h.app.kernel, entered: make(chan struct{}), release: make(chan struct{}), destroyed: make(chan string, 4)}
	h.app.kernel = gate
	var once sync.Once
	release := func() { once.Do(func() { close(gate.release) }) }
	t.Cleanup(release)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	select {
	case <-gate.entered:
	case <-time.After(debugAdapterExitWait):
		t.Fatal("the session create did not start")
	}
	h.app.stopDebug(p)
	release()
	awaitStateWithin(t, h, debugAdapterExitWait, "the stopped session", func() bool { return p.debug.activeSession() == nil })
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

func TestDebugHostedAdapterStartIsRecordedWhenItAnswersInitialize(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugHostedPluginID, debugHostedManifest, false, plugins)
	root, _ := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, false)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	p := openHostedPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "the paused hosted session", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused"
	})
	wantDebugStart(t, plugins.next(t, "the hosted adapter start"), debugHostedPluginID, session, "finished", "")
	h.app.stopDebug(p)
	awaitStateWithin(t, h, debugAdapterExitWait, "the stopped session", func() bool { return p.debug.activeSession() == nil })
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

func TestDebugHostedAdapterThatCannotBeReachedIsRecordedAsALaunchFailure(t *testing.T) {
	for name, port := range map[string]func(t *testing.T) func(context.Context, *project, debugAdapter) (int, error){
		"the endpoint command fails": func(*testing.T) func(context.Context, *project, debugAdapter) (int, error) {
			return func(context.Context, *project, debugAdapter) (int, error) {
				return 0, errors.New("the server has no debug command")
			}
		},
		"nothing listens on the port": func(t *testing.T) func(context.Context, *project, debugAdapter) (int, error) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			closed := listener.Addr().(*net.TCPAddr).Port
			_ = listener.Close()
			return func(context.Context, *project, debugAdapter) (int, error) { return closed, nil }
		},
	} {
		t.Run(name, func(t *testing.T) {
			plugins := newRecordingPluginKernel()
			h := debugPluginHarnessOn(t, debugHostedPluginID, debugHostedManifest, false, plugins)
			root, _ := fixtureWorkspace(t)
			h.app.debugHostedPort = port(t)
			p := openHostedPanel(t, h, root)
			h.app.startDebug(p)
			session := p.debug.activeSession()
			awaitStateWithin(t, h, debugAdapterExitWait, "the failure", func() bool { return p.debug.failure != "" })
			wantDebugStart(t, plugins.next(t, "the unreached adapter"), debugHostedPluginID, session, "failed", core.StageLaunch)
			awaitDebugSessionDone(t, session)
			plugins.none(t)
		})
	}
}

func TestDebugHostedAdapterThatNeverAnswersIsRecordedAsATimeout(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugHostedPluginID, debugHostedManifest, false, plugins)
	root, _ := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, true)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	h.app.debugInitializeWindow = 300 * time.Millisecond
	p := openHostedPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, debugAdapterExitWait, "the timeout", func() bool { return p.debug.failure != "" })
	wantDebugStart(t, plugins.next(t, "the silent adapter"), debugHostedPluginID, session, "failed", core.StageTimeout)
	awaitDebugSessionDone(t, session)
	plugins.none(t)
}

// The adapter's first answer Core read decides the start: a state that runs finishes it, one
// that ended fails it at initialize, and one still initializing leaves it open. A later answer
// changes nothing, and a stop records nothing.
func TestDebugAdapterAnswerEndsTheStartByItsState(t *testing.T) {
	plugins := newRecordingPluginKernel()
	h := debugPluginHarnessOn(t, debugFixturePluginID, debugFixtureManifest, true, plugins)
	for _, c := range []struct {
		state   string
		outcome string
		stage   core.PluginStage
	}{
		{state: ""}, {state: "idle"}, {state: "initializing"},
		{state: "ready", outcome: "finished"}, {state: "launching", outcome: "finished"},
		{state: "running", outcome: "finished"}, {state: "paused", outcome: "finished"},
		{state: "failed", outcome: "failed", stage: core.StageInitialize},
		{state: "terminating", outcome: "failed", stage: core.StageInitialize},
		{state: "terminated", outcome: "failed", stage: core.StageInitialize},
	} {
		id := "desktop-debug-answer-" + c.state
		session := &debugSession{id: id, ctx: context.Background(), adapterStart: core.StartPluginAttempt(debugFixturePluginID, core.OperationDebugAdapterStart, id)}
		h.app.debugAdapterAnswered(session, c.state)
		if c.outcome == "" {
			plugins.none(t)
			continue
		}
		wantDebugStart(t, plugins.next(t, "state "+c.state), debugFixturePluginID, session, c.outcome, c.stage)
		h.app.debugAdapterAnswered(session, "failed")
		plugins.none(t)
	}

	stopped, cancel := context.WithCancel(context.Background())
	cancel()
	session := &debugSession{id: "desktop-debug-stopped", ctx: stopped, adapterStart: core.StartPluginAttempt(debugFixturePluginID, core.OperationDebugAdapterStart, "desktop-debug-stopped")}
	h.app.debugAdapterAnswered(session, "failed")
	h.app.recordDebugStart(stopped, session, core.StageExit, errDebugAdapterExited)
	plugins.none(t)

	// A write past the session's write deadline is a timeout, whatever stage it was at.
	session = &debugSession{id: "desktop-debug-write", ctx: context.Background(), adapterStart: core.StartPluginAttempt(debugFixturePluginID, core.OperationDebugAdapterStart, "desktop-debug-write")}
	h.app.recordDebugStart(session.ctx, session, core.StageExit, &debugWriteTimedOut{cause: os.ErrClosed})
	wantDebugStart(t, plugins.next(t, "the timed-out write"), debugFixturePluginID, session, "failed", core.StageTimeout)

	// A write the hosted stream refused because it no longer runs leaves the start and the
	// session to that stream's own failure, which carries the reason.
	session = &debugSession{id: "desktop-debug-stream", ctx: context.Background(), adapterStart: core.StartPluginAttempt(debugHostedPluginID, core.OperationDebugAdapterStart, "desktop-debug-stream")}
	if finish := h.app.debugWriteFailed(nil, session, errDebugTransportNotRunning); finish != nil {
		t.Fatal("a write to a stream that no longer runs ended the session itself")
	}
	plugins.none(t)
}

func TestDebugAdapterFailureStages(t *testing.T) {
	for _, c := range []struct {
		reached bool
		reason  string
		want    core.PluginStage
	}{
		{reason: "startupTimedOut", want: core.StageTimeout},
		{reached: true, reason: "startupTimedOut", want: core.StageTimeout},
		{reason: "connectFailed", want: core.StageLaunch},
		{reached: true, reason: "readFailed", want: core.StageInitialize},
	} {
		if got := hostedFailureStage(c.reached, c.reason); got != c.want {
			t.Errorf("hostedFailureStage(%v, %q) = %q, want %q", c.reached, c.reason, got, c.want)
		}
	}
	for _, c := range []struct {
		stdio, reached bool
		want           core.PluginStage
	}{
		{stdio: true, reached: true, want: core.StageExit},
		{reached: true, want: core.StageInitialize},
		{want: core.StageLaunch},
	} {
		if got := debugWriteFailureStage(c.stdio, c.reached); got != c.want {
			t.Errorf("debugWriteFailureStage(%v, %v) = %q, want %q", c.stdio, c.reached, got, c.want)
		}
	}
	timedOut := &debugWriteTimedOut{cause: os.ErrClosed}
	if !errors.Is(timedOut, context.DeadlineExceeded) || !errors.Is(timedOut, os.ErrClosed) || timedOut.Error() != os.ErrClosed.Error() {
		t.Fatalf("debugWriteTimedOut = %v, want the write's text that is also a deadline", timedOut)
	}
}
