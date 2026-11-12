package buildprovider

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"testing"
	"time"
)

type functionKernel struct {
	pending bool
	pluginbackend.Kernel
	client                         *Client
	fail                           error
	cancelSession, cancelOperation string
}

func (k *functionKernel) InvokePluginFunction(_ context.Context, session, operation, plugin, function string, params json.RawMessage) (string, error) {
	if k.fail != nil {
		return "", k.fail
	}
	if session != "shared-session" || plugin != "dev.example.provider" || function != "index.refresh" || string(params) != "{}" {
		return "", errors.New("function was retargeted")
	}
	// Core can complete before the submission returns; the single event owner
	// must already know the operation when these synchronous events arrive.
	k.client.Observe(core.BackendEvent{Type: "requestProgress", OperationID: operation, Result: json.RawMessage(`{"message":"fixture progress"}`)})
	if !k.pending {
		k.client.Observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: json.RawMessage(`{"value":null}`)})
	}
	return operation, nil
}
func (k *functionKernel) CancelPluginOperation(_ context.Context, session, operation string) error {
	k.cancelSession, k.cancelOperation = session, operation
	if k.pending {
		k.client.Observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Error: json.RawMessage(`{"code":"cancelled","message":"fixture cancellation"}`)})
	}
	return nil
}

func TestFunctionSharesProviderEventStreamAndCancellation(t *testing.T) {
	kernel := &functionKernel{}
	client := Attach(pluginbackend.New(kernel, nil), pluginbackend.Session{ID: "shared-session", PluginID: "dev.example.provider"}, true)
	kernel.client = client
	defer client.Close(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	operation, err := client.ExecuteFunction(ctx, "index.refresh", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	value, err := operation.Wait(ctx)
	if err != nil || string(value) != "null" {
		t.Fatalf("function result: %s %v", value, err)
	}
	select {
	case progress, open := <-operation.Progress():
		if !open || progress.Message != "fixture progress" {
			t.Fatalf("progress: %+v, open=%v", progress, open)
		}
	case <-ctx.Done():
		t.Fatal("function progress did not finish before the local deadline")
	}
	select {
	case _, open := <-operation.Progress():
		if open {
			t.Fatal("terminal progress channel remained open")
		}
	case <-ctx.Done():
		t.Fatal("terminal progress channel did not close before the local deadline")
	}

}

func TestFunctionSubmissionFailureLeavesNoPendingOperation(t *testing.T) {
	failure := errors.New("fixture function refused")
	kernel := &functionKernel{fail: failure}
	client := Attach(pluginbackend.New(kernel, nil), pluginbackend.Session{ID: "shared-session", PluginID: "dev.example.provider"}, true)
	defer client.Close(context.Background())
	if _, err := client.ExecuteFunction(context.Background(), "index.refresh", json.RawMessage(`{}`)); !errors.Is(err, failure) {
		t.Fatalf("submission: %v", err)
	}
	client.mu.Lock()
	pending := len(client.pending)
	client.mu.Unlock()
	if pending != 0 {
		t.Fatalf("%d pending operations after refusal", pending)
	}
}

func TestPendingFunctionCanBeCancelledThroughSharedSession(t *testing.T) {
	kernel := &functionKernel{pending: true}
	client := Attach(pluginbackend.New(kernel, nil), pluginbackend.Session{ID: "shared-session", PluginID: "dev.example.provider"}, true)
	kernel.client = client
	defer client.Close(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	operation, err := client.ExecuteFunction(ctx, "index.refresh", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-operation.Done():
		t.Fatal("pending function completed before cancellation")
	default:
	}
	if err := client.Cancel(ctx, operation); err != nil {
		t.Fatal(err)
	}
	if kernel.cancelSession != "shared-session" || kernel.cancelOperation != operation.ID {
		t.Fatal("cancel retargeted the operation")
	}
	if _, err := operation.Wait(ctx); err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("cancel terminal event: %v", err)
	}
}
