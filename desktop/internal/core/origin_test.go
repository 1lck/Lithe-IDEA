package core

import (
	"context"
	"encoding/json"
	"testing"
)

// TestRequestOriginReportsTheActionAndItsSource checks what each kind of context reports: nothing
// without an action, the action as a user request, and an automatic refresh as background even
// when an action started it.
func TestRequestOriginReportsTheActionAndItsSource(t *testing.T) {
	ctx := context.Background()
	action := Origin{Operation: "action-7", Trigger: "command.git.commit"}
	cases := []struct {
		name string
		ctx  context.Context
		want string
	}{
		{"no action", ctx, `null`},
		{"an origin without an operation", WithOrigin(ctx, Origin{Trigger: "command.git.commit"}), `null`},
		{"an action", WithOrigin(ctx, action), `{"source":"user","trigger":"command.git.commit","operation":"action-7"}`},
		{"a refresh", AutomaticRefresh(ctx), `{"source":"background"}`},
		{"a refresh an action started", AutomaticRefresh(WithOrigin(ctx, action)), `{"source":"background","trigger":"command.git.commit","operation":"action-7"}`},
	}
	for _, c := range cases {
		encoded, err := json.Marshal(requestOriginOf(c.ctx))
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if string(encoded) != c.want {
			t.Errorf("%s: origin = %s, want %s", c.name, encoded, c.want)
		}
	}
	if got := OriginOf(WithOrigin(ctx, action)); got != action {
		t.Errorf("OriginOf = %+v, want %+v", got, action)
	}
}

// TestCoreRecordsTheRequestsOfAnActionUnderItsOp sends failing requests with the real kernel and
// reads back the terminal facts Core recorded for them: each carries the action's op, trigger
// and source, so the host's records of an action and Core's records of its requests share an op.
func TestCoreRecordsTheRequestsOfAnActionUnderItsOp(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	if err := c.ConfigureCoreEvents(ctx, false, nil); err != nil {
		t.Fatalf("ConfigureCoreEvents: %v", err)
	}
	if _, err := c.DrainCoreEvents(ctx); err != nil {
		t.Fatalf("DrainCoreEvents: %v", err)
	}
	user, refresh := NewOperation(), NewOperation()
	if user == refresh {
		t.Fatalf("NewOperation returned %q twice", user)
	}
	const command = "test.noSuchCommand"
	if err := c.Execute(WithOrigin(ctx, Origin{Operation: user, Trigger: "test.origin"}), command, nil, nil); err == nil {
		t.Fatalf("%s succeeded", command)
	}
	if err := c.Execute(AutomaticRefresh(WithOrigin(ctx, Origin{Operation: refresh, Trigger: "test.refresh"})), command, nil, nil); err == nil {
		t.Fatalf("%s succeeded", command)
	}
	drained, err := c.DrainCoreEvents(ctx)
	if err != nil {
		t.Fatalf("DrainCoreEvents: %v", err)
	}
	found := map[string]CoreEvent{}
	for _, event := range drained.Events {
		if event.Event == "app.core.request.failed" && (event.Op == user || event.Op == refresh) {
			found[event.Op] = event
		}
	}
	for op, want := range map[string][2]string{user: {"user", "test.origin"}, refresh: {"background", "test.refresh"}} {
		event, ok := found[op]
		if !ok {
			t.Fatalf("no app.core.request.failed under op %s in %+v", op, drained.Events)
		}
		if event.Level != LevelWarn || event.Fields["method"] != command || event.Fields["source"] != want[0] || event.Fields["trigger"] != want[1] {
			t.Errorf("op %s: %+v, want a WARN of %s with source %s and trigger %s", op, event, command, want[0], want[1])
		}
	}
}
