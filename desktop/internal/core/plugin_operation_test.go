package core

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// TestPluginOperationWireShape checks the payload Core's strict ingress takes: a finished
// result names no stage, and an absent operation ID is left out rather than sent as null.
func TestPluginOperationWireShape(t *testing.T) {
	for _, tc := range []struct {
		operation PluginOperation
		want      string
	}{
		{
			PluginOperation{PluginID: "io.example.go", Operation: OperationBuildModel, Outcome: "finished", DurationMs: 12, OperationID: "action-3"},
			`{"pluginId":"io.example.go","operation":"lithe/build/model","outcome":"finished","durationMs":12,"operationId":"action-3"}`,
		},
		{
			PluginOperation{PluginID: "io.example.go", Operation: OperationDebugAdapterStart, Outcome: "failed", Stage: StageLaunch},
			`{"pluginId":"io.example.go","operation":"debugAdapter/start","outcome":"failed","stage":"launch","durationMs":0}`,
		},
	} {
		got, err := json.Marshal(tc.operation)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != tc.want {
			t.Fatalf("payload = %s, want %s", got, tc.want)
		}
	}
	handoff, err := json.Marshal(PluginBackendStart{StartupOperation: &StartupOperation{PluginID: "p", OperationID: "action-1", ElapsedMs: 4}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(handoff), `"startupOperation":{"pluginId":"p","operationId":"action-1","elapsedMs":4}`) {
		t.Fatalf("lsp.startServer carries the handoff as %s", handoff)
	}
	plain, err := json.Marshal(PluginBackendStart{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plain), "startupOperation") {
		t.Fatalf("a start without an attempt still names one: %s", plain)
	}
}

// TestPluginAttemptYieldsOneResult checks that an attempt yields one result at most, whoever
// ends it first, that a handoff leaves the host nothing to record, that a cancellation is
// never a result, and that a deadline is a timeout whatever stage it stopped.
func TestPluginAttemptYieldsOneResult(t *testing.T) {
	ctx := context.Background()

	attempt := StartPluginAttempt("p", OperationBuildModel, "action-9")
	finished, ok := attempt.Ended(ctx, StageExit, nil)
	if !ok || finished.Outcome != "finished" || finished.Stage != "" || finished.OperationID != "action-9" || finished.PluginID != "p" || finished.Operation != OperationBuildModel {
		t.Fatalf("finished attempt = %+v, %v", finished, ok)
	}
	if again, ok := attempt.Ended(ctx, StageExit, errors.New("late")); ok {
		t.Fatalf("an ended attempt yielded a second result %+v", again)
	}
	if attempt.HandOff() != nil {
		t.Fatal("an ended attempt was handed to Core")
	}

	failed, ok := StartPluginAttempt("p", OperationBuildModel, "action-9").Ended(ctx, StageDecode, errors.New("bad output"))
	if !ok || failed.Outcome != "failed" || failed.Stage != StageDecode {
		t.Fatalf("failed attempt = %+v, %v", failed, ok)
	}

	timed, ok := StartPluginAttempt("p", OperationBuildModel, "action-9").Ended(ctx, StageExit, context.DeadlineExceeded)
	if !ok || timed.Stage != StageTimeout {
		t.Fatalf("an attempt past its deadline = %+v, %v, want a timeout", timed, ok)
	}
	expired, stop := context.WithTimeout(ctx, 0)
	defer stop()
	<-expired.Done()
	if timed, ok := StartPluginAttempt("p", OperationBuildModel, "action-9").Ended(expired, StageExit, errors.New("signal: killed")); !ok || timed.Stage != StageTimeout {
		t.Fatalf("an attempt whose context expired = %+v, %v, want a timeout", timed, ok)
	}

	cancelled := StartPluginAttempt("p", OperationBuildModel, "action-9")
	if result, ok := cancelled.Ended(ctx, StageExit, context.Canceled); ok {
		t.Fatalf("a cancellation was recorded as %+v", result)
	}
	stopped, cancel := context.WithCancel(ctx)
	cancel()
	if result, ok := StartPluginAttempt("p", OperationBuildModel, "action-9").Ended(stopped, StageExit, errors.New("signal: killed")); ok {
		t.Fatalf("an attempt the user stopped was recorded as %+v", result)
	}
	// A cancellation leaves the attempt open, so the result of the work that went on anyway
	// is still the attempt's one result.
	if _, ok := cancelled.Ended(ctx, StageExit, nil); !ok {
		t.Fatal("a cancelled report used up the attempt")
	}

	abandoned := StartPluginAttempt("p", OperationBuildModel, "action-9")
	abandoned.Abandon()
	if result, ok := abandoned.Ended(ctx, StageExit, nil); ok {
		t.Fatalf("an abandoned attempt was recorded as %+v", result)
	}

	handed := StartPluginAttempt("p", OperationLanguageServerStart, "action-9")
	handoff := handed.HandOff()
	if handoff == nil || handoff.PluginID != "p" || handoff.OperationID != "action-9" || handoff.ElapsedMs < 0 || !handed.HandedOff() {
		t.Fatalf("handoff = %+v", handoff)
	}
	if handed.HandOff() != nil {
		t.Fatal("an attempt was handed to Core twice")
	}
	if result, ok := handed.Ended(ctx, StageResolve, errors.New("refused")); ok {
		t.Fatalf("the host recorded %+v for an attempt Core owns", result)
	}

	var none *PluginAttempt
	if none.HandOff() != nil || none.HandedOff() || none.OperationID() != "" {
		t.Fatal("a nil attempt is not inert")
	}
	if _, ok := none.Ended(ctx, StageExit, nil); ok {
		t.Fatal("a nil attempt yielded a result")
	}
	none.Abandon()
}

// TestPluginAttemptKeepsOnlyOperationIDsCoreTakes checks that an op Core would refuse as an
// operation ID is replaced by a fresh one, since a handoff and a correlated result need one.
func TestPluginAttemptKeepsOnlyOperationIDsCoreTakes(t *testing.T) {
	for _, kept := range []string{"action-12", "a.b_c:d/e-f", strings.Repeat("a", 128)} {
		if got := StartPluginAttempt("p", OperationBuildModel, kept).OperationID(); got != kept {
			t.Fatalf("op %q became %q", kept, got)
		}
	}
	for _, replaced := range []string{"", "with space", "dollar$", "at@sign", "plus+", strings.Repeat("a", 129), "é"} {
		got := StartPluginAttempt("p", OperationBuildModel, replaced).OperationID()
		if got == replaced || !strings.HasPrefix(got, "action-") {
			t.Fatalf("op %q was kept as %q, want a fresh one", replaced, got)
		}
	}
}

// TestCoreTakesEveryResultTheHostRecords sends the real kernel every result the host can
// record, for each contribution and each stage its lifecycle reaches, and reads back the facts:
// each lands on the plugin's host channel under its op with the stage's code. A stage the
// lifecycle cannot reach is refused, so the host's stage choices are checked against Core's
// own table rather than a copy of it.
func TestCoreTakesEveryResultTheHostRecords(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	if _, err := c.DrainCoreEvents(ctx); err != nil {
		t.Fatalf("DrainCoreEvents: %v", err)
	}
	processStart := map[PluginStage]string{
		StageResolve: "host.executableUnavailable", StageLaunch: "host.launchFailed", StageInitialize: "host.initializeFailed",
		StageTimeout: "host.timedOut", StageExit: "host.exitedEarly",
	}
	commandRun := map[PluginStage]string{
		StagePlan: "host.planFailed", StageResolve: "host.executableUnavailable", StageLaunch: "host.launchFailed",
		StageTimeout: "host.timedOut", StageExit: "host.commandFailed", StageDecode: "host.outputInvalid",
	}
	contributions := map[PluginOperationName]map[PluginStage]string{
		OperationLanguageServerStart: processStart, OperationDebugAdapterStart: processStart,
		OperationBuildModel: commandRun, OperationBuildDependencies: commandRun, OperationBuildTestDiscovery: commandRun,
	}
	allStages := []PluginStage{StagePlan, StageResolve, StageLaunch, StageInitialize, StageTimeout, StageExit, StageDecode}
	want := map[string]string{} // op -> code, "" for finished
	for operation, codes := range contributions {
		finished := NewOperation()
		if err := c.RecordPluginOperation(ctx, PluginOperation{PluginID: "io.example.go", Operation: operation, Outcome: "finished", DurationMs: 1, OperationID: finished}); err != nil {
			t.Fatalf("%s finished: %v", operation, err)
		}
		want[finished] = ""
		for _, stage := range allStages {
			op := NewOperation()
			err := c.RecordPluginOperation(ctx, PluginOperation{PluginID: "io.example.go", Operation: operation, Outcome: "failed", Stage: stage, DurationMs: 1, OperationID: op})
			code, reachable := codes[stage]
			var refused *LogError
			switch {
			case reachable && err != nil:
				t.Fatalf("%s failed at %s: %v", operation, stage, err)
			case reachable:
				want[op] = code
			case !errors.As(err, &refused) || refused.Code != -32064:
				t.Fatalf("%s at unreachable stage %s answered %v, want -32064", operation, stage, err)
			}
		}
	}
	drained, err := c.DrainCoreEvents(ctx)
	if err != nil {
		t.Fatalf("DrainCoreEvents: %v", err)
	}
	for _, event := range drained.Events {
		code, ok := want[event.Op]
		if !ok {
			continue
		}
		delete(want, event.Op)
		wantEvent := "plugins.operation.failed"
		if code == "" {
			wantEvent = "plugins.operation.finished"
		}
		if event.Event != wantEvent || event.Channel != "plugins/io.example.go/host" || (code != "" && event.Fields["code"] != code) {
			t.Errorf("op %s: %+v, want %s on plugins/io.example.go/host with code %q", event.Op, event, wantEvent, code)
		}
	}
	if len(want) != 0 {
		t.Fatalf("Core recorded no fact for %d results: %v", len(want), want)
	}
}
