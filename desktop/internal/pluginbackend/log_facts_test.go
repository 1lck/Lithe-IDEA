package pluginbackend

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// loggedFact is one fact the runner handed to its sink.
type loggedFact struct {
	level  core.LogLevel
	event  string
	fields map[string]any
}

// factRecorder collects the facts a runner forwards; the runner calls it on the goroutine
// that serves or stops the session, which is the test's own here.
type factRecorder struct{ facts []loggedFact }

func (r *factRecorder) record(level core.LogLevel, event string, fields map[string]any) {
	r.facts = append(r.facts, loggedFact{level: level, event: event, fields: fields})
}

// TestServeForwardsEveryLogFactOnce checks that Serve hands each catalog fact Core attached
// to a runtime event to the sink exactly once, whatever the event's type, the exit included;
// that an event without a fact, or whose fact Core could not prepare, forwards nothing; and
// that numbers reach the sink as written rather than rounded through float64.
func TestServeForwardsEveryLogFactOnce(t *testing.T) {
	kernel := &fakeKernel{events: [][]core.BackendEvent{{
		{Type: "log", Event: "lsp.stderr.received", Level: "DEBUG", Fields: json.RawMessage(`{"text":"warming up","bytes":9007199254740993}`)},
		{Type: "log", Message: "a line Core kept only for the v1 log"},
		{Type: "stateChanged", State: "running", Event: "lsp.session.updated", Level: "INFO"},
		{Type: "log", Level: "WARN", Fields: json.RawMessage(`{"text":"no id"}`)},
		{Type: "log", Event: "lsp.message.logged", Level: "INFO", Fields: json.RawMessage(`not json`)},
	}, {
		{Type: EventExit, Event: "lsp.session.failed", Level: "ERROR", Fields: json.RawMessage(`{"stage":"exit"}`)},
	}}}
	facts := &factRecorder{}
	runner := New(kernel, echoServices(t))
	runner.SetLogFacts(facts.record)
	if err := runner.Serve(context.Background(), Session{ID: "session-1"}, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}

	want := []loggedFact{
		{level: core.LevelDebug, event: "lsp.stderr.received", fields: map[string]any{"text": "warming up", "bytes": json.Number("9007199254740993")}},
		{level: core.LevelInfo, event: "lsp.session.updated", fields: map[string]any{}},
		{level: core.LevelError, event: "lsp.session.failed", fields: map[string]any{"stage": "exit"}},
	}
	if len(facts.facts) != len(want) {
		t.Fatalf("forwarded %d facts, want %d: %+v", len(facts.facts), len(want), facts.facts)
	}
	for i, got := range facts.facts {
		if got.level != want[i].level || got.event != want[i].event || !sameFields(got.fields, want[i].fields) {
			t.Fatalf("fact %d = %+v, want %+v", i, got, want[i])
		}
	}
}

// TestStopForwardsTheLastFactsItWaitsThrough checks that the lifecycle facts a session
// reports while Stop waits for Core to let go of it reach the sink, instead of being read
// and dropped because nothing serves the session any more.
func TestStopForwardsTheLastFactsItWaitsThrough(t *testing.T) {
	kernel := &stoppingKernel{fakeKernel: fakeKernel{events: [][]core.BackendEvent{{
		{Type: "stateChanged", State: "stopped", Event: "lsp.session.updated", Level: "INFO", Fields: json.RawMessage(`{"state":"stopped"}`)},
	}}}, refusals: 1}
	facts := &factRecorder{}
	runner := New(kernel, nil)
	runner.SetLogFacts(facts.record)
	if err := runner.Stop(context.Background(), Session{ID: "session-1"}); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if len(facts.facts) != 1 || facts.facts[0].event != "lsp.session.updated" || facts.facts[0].fields["state"] != "stopped" {
		t.Fatalf("Stop forwarded %+v, want the stopped session's update once", facts.facts)
	}
}

func TestStopDisposesAfterServeDrainsTheTerminalEvents(t *testing.T) {
	for _, state := range []string{"sessionStopped", "sessionFailed"} {
		t.Run(state, func(t *testing.T) {
			kernel := &stoppingKernel{
				refusals: 1,
				waitErr: &core.Error{
					Command: "lsp.waitEvents",
					Code:    core.CodeProcessFailed,
					Details: state,
				},
			}
			disposed, err := New(kernel, nil).StopAndDispose(context.Background(), Session{ID: "session-1"})
			if !disposed || !kernel.destroyed || err != nil {
				t.Fatalf("stop and dispose after terminal events were drained: disposed=%v, destroyed=%v, err=%v", disposed, kernel.destroyed, err)
			}
		})
	}
}

func TestStopReportsAnEventWaitFailure(t *testing.T) {
	waitErr := &core.Error{Command: "lsp.waitEvents", Code: core.CodeProcessFailed, Details: "transport failed"}
	kernel := &stoppingKernel{refusals: 1, waitErr: waitErr}
	disposed, err := New(kernel, nil).StopAndDispose(context.Background(), Session{ID: "session-1"})
	if disposed || kernel.destroyed || !errors.Is(err, waitErr) {
		t.Fatalf("stop and dispose after wait fails: disposed=%v, destroyed=%v, err=%v", disposed, kernel.destroyed, err)
	}
}

// TestRunnerWithoutLogSinkDropsFacts checks that a runner nobody gave a sink still serves
// its session.
func TestRunnerWithoutLogSinkDropsFacts(t *testing.T) {
	kernel := &fakeKernel{events: [][]core.BackendEvent{{
		{Type: EventExit, Event: "lsp.session.failed", Level: "ERROR", Fields: json.RawMessage(`{"stage":"exit"}`)},
	}}}
	if err := New(kernel, echoServices(t)).Serve(context.Background(), Session{ID: "session-1"}, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}
}

// stoppingKernel refuses the first destroys, as Core does while a session is still
// shutting down.
type stoppingKernel struct {
	fakeKernel
	refusals int
	waitErr  error
}

func (k *stoppingKernel) WaitBackendEvents(ctx context.Context, session string, timeout int) ([]core.BackendEvent, error) {
	if k.waitErr != nil {
		return nil, k.waitErr
	}
	return k.fakeKernel.WaitBackendEvents(ctx, session, timeout)
}

func (k *stoppingKernel) DestroyPluginBackend(ctx context.Context, session string) error {
	if k.refusals > 0 {
		k.refusals--
		return errors.New("session is still stopping")
	}
	return k.fakeKernel.DestroyPluginBackend(ctx, session)
}

func sameFields(got, want map[string]any) bool {
	if len(got) != len(want) {
		return false
	}
	for key, value := range want {
		if got[key] != value {
			return false
		}
	}
	return true
}
