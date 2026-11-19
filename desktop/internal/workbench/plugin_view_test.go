package workbench

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// A failed view call, a deadline among them, is logged as a failure the user sees; a call
// the view's closing cancelled is not a failure and writes nothing.
func TestViewCallFailedLogsAFailureButNotACancelledCall(t *testing.T) {
	log := &opRecordingLog{}
	a := &App{logSink: log}
	ctx := context.Background()
	a.viewCallFailed(ctx, pluginViewOperation, nil)
	a.viewCallFailed(ctx, pluginViewOperation, context.Canceled)
	a.viewCallFailed(ctx, pluginViewOperation, fmt.Errorf("plugin view: %w", context.Canceled))
	if len(log.records) != 0 {
		t.Fatalf("a call that did not fail was logged: %v", log.records)
	}
	a.viewCallFailed(ctx, pluginViewOperation, errors.New("the backend exited"))
	a.viewCallFailed(ctx, pluginViewOperation, context.DeadlineExceeded)
	if got := log.ops(operationFailedEvent); len(got) != 2 {
		t.Fatalf("failed calls wrote %d %s records, want two: %v", len(got), operationFailedEvent, log.records)
	}
	if got := log.ops(backgroundFailedEvent); len(got) != 0 {
		t.Fatalf("a failure the view draws was logged as background work: %v", got)
	}
}
