package pluginservice

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type actionRefreshWorkbench struct {
	*fakeWorkbench
	roots []string
}

func (w *actionRefreshWorkbench) EditorActionsChanged(root string) { w.roots = append(w.roots, root) }

func TestEditorActionRegistrationRefreshesOpenDocuments(t *testing.T) {
	observer := &actionRefreshWorkbench{fakeWorkbench: &fakeWorkbench{}}
	service, workspace := openDecodedEditorService(t, observer)
	service.Host.mu.Lock()
	service.Host.sessions["a"] = &BackendSession{host: service.Host, PluginID: "a", Session: pluginbackend.Session{ID: "session-a"}, functions: map[string]bool{"actions.collect": true}, waiters: map[string]chan core.BackendEvent{}, done: make(chan struct{}), changed: make(chan struct{}), ready: true}
	service.Host.mu.Unlock()
	body := `{` + contextJSONOf(workspace) + `,"id":"actions","function":"actions.collect","selector":{"fileExtensions":["java"]}}`
	if _, refusal := respond(t, service, "a", "editor/registerActions", body); refusal != nil {
		t.Fatalf("register: %+v", refusal)
	}
	if len(observer.roots) != 1 || observer.roots[0] != workspace.Path {
		t.Fatalf("registration did not refresh documents: %v", observer.roots)
	}
	if _, refusal := respond(t, service, "a", "editor/registerActions", body); refusal == nil {
		t.Fatal("duplicate accepted")
	}
	if len(observer.roots) != 1 {
		t.Fatal("rejected registration refreshed documents")
	}
	service.resources.releaseContext(workspace.ContextID)
	if len(observer.roots) != 2 {
		t.Fatalf("withdrawal did not clear actions: %v", observer.roots)
	}
}

// Use the real decoder: the lightweight host test kernel deliberately omits it.
type realActionDecoder struct{ *notifyKernel }

func (k *realActionDecoder) DecodeEditorActions(ctx context.Context, payload any) (json.RawMessage, error) {
	return core.NewClient().DecodeEditorActions(ctx, payload)
}

func (k *realActionDecoder) DecodeEditorProviders(ctx context.Context, payload any) (json.RawMessage, error) {
	return core.NewClient().DecodeEditorProviders(ctx, payload)
}

// Assemble dependencies before opening the context. Function relay startup is not
// part of declaration validation; keep this unit test free of background observers.
func openDecodedEditorService(t *testing.T, window Workbench) (*Service, WorkspaceContext) {
	t.Helper()
	kernel := &realActionDecoder{notifyKernel: &notifyKernel{}}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkbench(window); err != nil {
		t.Fatal(err)
	}
	service.Contexts.SetObserver(nil)
	t.Cleanup(service.Contexts.CloseAll)
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return service, service.Contexts.Open(root)
}
