package buildprovider

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

func TestAttachWaitsForRealReady(t *testing.T) {
	client := Attach(nil, pluginbackend.Session{ID: "shared"}, false)
	defer client.Close(context.Background())
	select {
	case <-client.ready:
		t.Fatal("Attach reported ready before the session's ready event")
	default:
	}
	client.Observe(core.BackendEvent{Type: "stateChanged", State: "ready"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.WaitReady(ctx); err != nil {
		t.Fatalf("wait for the real ready event: %v", err)
	}
}

func TestAttachAlreadyReadySession(t *testing.T) {
	client := Attach(nil, pluginbackend.Session{ID: "shared"}, true)
	defer client.Close(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.WaitReady(ctx); err != nil {
		t.Fatalf("an already-ready session was not ready: %v", err)
	}
	// A forwarded ready event must be harmless after Attach recorded readiness.
	client.Observe(core.BackendEvent{Type: "stateChanged", State: "ready"})
}

func TestOperationTerminalIsIdempotent(t *testing.T) {
	operation := newOperation("op", "lithe/build/model")
	operation.fail(errors.New("first"))
	operation.fail(errors.New("second"))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := operation.Wait(ctx)
	if err == nil || !strings.Contains(err.Error(), "first") {
		t.Fatalf("terminal error = %v, want the first failure", err)
	}
	if _, open := <-operation.Progress(); open {
		t.Fatal("progress channel is still open after a terminal event")
	}
}

func TestProgressCannotSendAfterTerminal(t *testing.T) {
	client := newClient(nil, pluginbackend.Session{ID: "shared"})
	operation := newOperation("op", "lithe/build/execute")
	client.pending["op"] = operation
	operation.fail(ErrClosed)
	// The observer may still hold this operation pointer after failAll closed
	// its channels. Delivery must be inert, not a send on a closed channel.
	client.Observe(core.BackendEvent{
		Type:        "requestProgress",
		OperationID: "op",
		Result:      json.RawMessage(`{"message":"late progress"}`),
	})
}

func TestCloseTerminalizesPendingProgress(t *testing.T) {
	client := Attach(nil, pluginbackend.Session{ID: "shared"}, true)
	operation := newOperation("op", "lithe/build/execute")
	client.pending["op"] = operation
	if err := client.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}
	if _, open := <-operation.Progress(); open {
		t.Fatal("Close left the progress channel open")
	}
	if _, open := <-operation.Done(); open {
		t.Fatal("Close left the done channel open")
	}
	client.Observe(core.BackendEvent{
		Type:        "requestProgress",
		OperationID: "op",
		Result:      json.RawMessage(`{"message":"after close"}`),
	})
}

func TestRequestFailureRacesFailAll(t *testing.T) {
	kernel := &blockingRequestKernel{started: make(chan struct{}), release: make(chan struct{})}
	client := newClient(pluginbackend.New(kernel, nil), pluginbackend.Session{ID: "session"})
	client.markReady()
	done := make(chan error, 1)
	go func() {
		_, err := client.Execute(context.Background(), "lithe/build/model", json.RawMessage(`{"task":"build"}`), 1000)
		done <- err
	}()
	select {
	case <-kernel.started:
	case <-time.After(5 * time.Second):
		t.Fatal("the request was not registered")
	}
	// take the operation before RequestBuild returns; the failure path then
	// finalizes the same operation a second time.
	client.failAll(ErrClosed)
	close(kernel.release)
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Execute succeeded after RequestBuild failed")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Execute did not return")
	}
	client.mu.Lock()
	pending := len(client.pending)
	client.mu.Unlock()
	if pending != 0 {
		t.Fatalf("%d operations remained pending after the failure", pending)
	}
}

type blockingRequestKernel struct {
	pluginbackend.Kernel
	started chan struct{}
	release chan struct{}
}

func (k *blockingRequestKernel) RequestPluginBuild(context.Context, core.PluginBuildProviderRequest) (string, error) {
	close(k.started)
	<-k.release
	return "", errors.New("request rejected")
}

// Core keeps a provider's JSON-RPC error under its serverError code and generic message and
// passes the provider's own message apart; the window shows that message, logs keep only Core's.
func TestProviderErrorKeepsTheProvidersOwnMessageApart(t *testing.T) {
	err := providerError(json.RawMessage(`{"code":"serverError","stage":"request","method":"lithe/build/prepareRun","message":"Language server returned an error.","underlyingMessage":"{\"code\":-32603,\"message\":\"Choose the installation in the plugin's settings.\"}"}`))
	var failure *ProviderError
	if !errors.As(err, &failure) {
		t.Fatalf("decoded %T, want *ProviderError", err)
	}
	if failure.UserMessage() != "Choose the installation in the plugin's settings." {
		t.Fatalf("user message = %q, want the provider's", failure.UserMessage())
	}
	if strings.Contains(err.Error(), "installation") {
		t.Fatalf("Error, which logs record, carries the plugin's text: %q", err.Error())
	}
	for _, raw := range []string{
		`{"code":"timeout","message":"The request timed out."}`,
		`{"code":"serverError","message":"The request timed out.","underlyingMessage":"not a JSON-RPC error"}`,
	} {
		plain := providerError(json.RawMessage(raw))
		if !errors.As(plain, &failure) || failure.UserMessage() != "The request timed out." {
			t.Fatalf("a failure without a provider message = %v", plain)
		}
	}
}

// Drain returns once the operations running when it was called ended, and at once when the
// session ended first.
func TestDrainWaitsForRunningOperations(t *testing.T) {
	client := newClient(nil, pluginbackend.Session{ID: "shared"})
	operation := newOperation("op", "lithe/build/execute")
	client.pending["op"] = operation
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	drained := make(chan error, 1)
	go func() { drained <- client.Drain(ctx) }()
	select {
	case err := <-drained:
		t.Fatalf("Drain returned while an operation still ran: %v", err)
	default:
	}
	client.Observe(core.BackendEvent{Type: "requestCompleted", OperationID: "op", Result: json.RawMessage(`{"value":{}}`)})
	select {
	case err := <-drained:
		if err != nil {
			t.Fatalf("Drain: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("Drain did not return after the operation completed")
	}

	idle := newClient(nil, pluginbackend.Session{ID: "idle"})
	if err := idle.Drain(ctx); err != nil {
		t.Fatalf("Drain of an idle client: %v", err)
	}
}
