package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// progressKernel answers an invocation with one progress update of that
// operation, one of another operation, and then the completion.
type progressKernel struct {
	fakeKernel
	backend *BackendSession
}

func (k *progressKernel) InvokePluginFunctionInContext(_ context.Context, _, operation, _, _ string, _, _ json.RawMessage, _ int) (string, error) {
	go func() {
		k.backend.observe(core.BackendEvent{Type: "requestProgress", OperationID: "other", Result: json.RawMessage(`{"message":"not mine"}`)})
		k.backend.observe(core.BackendEvent{Type: "requestProgress", OperationID: operation, Result: json.RawMessage(`{"operationID":"` + operation + `","percentage":50}`)})
		k.backend.observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: json.RawMessage(`{"value":1}`)})
	}()
	return operation, nil
}

func TestPageCallsReceiveOnlyTheirProgress(t *testing.T) {
	kernel := &progressKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	backend := &BackendSession{
		host: service.Host, PluginID: "a", ready: true,
		Session:   pluginbackend.Session{ID: "backend-1"},
		functions: map[string]bool{"refresh": true}, waiters: map[string]chan core.BackendEvent{},
		progress: map[string]func(json.RawMessage){},
		done:     make(chan struct{}), changed: make(chan struct{}),
	}
	kernel.backend = backend
	service.Host.sessions["a"] = backend
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// The completion is routed after the progress on the same goroutine, so
	// every update has been handed over when the call returns.
	var updates []string
	value, err := service.Host.CallWithProgress(ctx, "a", "refresh", json.RawMessage(`{}`), nil, time.Second, func(update json.RawMessage) {
		updates = append(updates, string(update))
	})
	if err != nil || string(value) != "1" {
		t.Fatalf("call = %s %v", value, err)
	}
	if len(updates) != 1 || !strings.Contains(updates[0], `"percentage":50`) {
		t.Fatalf("progress = %v", updates)
	}
	if len(backend.progress) != 0 {
		t.Fatal("the finished call kept its progress route")
	}
	functions, err := service.Host.Functions(ctx, "a")
	if err != nil || len(functions) != 1 || functions[0] != "refresh" {
		t.Fatalf("functions = %v %v", functions, err)
	}
}

func TestPageStateIsKeptPerWindowAndWorkspace(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	const limit = 16
	if state, err := service.PageState("a", "a.window", "/work/one", limit); err != nil || state != nil {
		t.Fatalf("empty state = %q %v", state, err)
	}
	if err := service.SetPageState("a", "a.window", "/work/one", []byte(`{"tab":1}`), limit); err != nil {
		t.Fatal(err)
	}
	if state, err := service.PageState("a", "a.window", "/work/one", limit); err != nil || string(state) != `{"tab":1}` {
		t.Fatalf("state = %q %v", state, err)
	}
	for _, other := range [][2]string{{"a.window", "/work/two"}, {"a.other", "/work/one"}} {
		if state, _ := service.PageState("a", other[0], other[1], limit); state != nil {
			t.Fatalf("%v saw another window's state: %q", other, state)
		}
	}
	if err := service.SetPageState("a", "a.window", "/work/one", []byte(`"0123456789abcdef"`), limit); !errors.Is(err, ErrPageStateTooLarge) {
		t.Fatalf("oversized state = %v", err)
	}
	if err := service.SetPageState("a", "a.window", "/work/one", nil, limit); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(service.pageStatePath("a", "a.window", "/work/one")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cleared state remains: %v", err)
	}
}
