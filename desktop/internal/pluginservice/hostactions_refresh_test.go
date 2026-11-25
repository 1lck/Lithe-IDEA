package pluginservice

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
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

func (k *realActionDecoder) PluginWorkflow(ctx context.Context, payload, result any) error {
	return core.NewClient().PluginWorkflow(ctx, payload, result)
}

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
	return openEditorServiceWith(t, &realActionDecoder{notifyKernel: &notifyKernel{}}, window)
}

func openEditorServiceWith(t *testing.T, kernel Kernel, window Workbench) (*Service, WorkspaceContext) {
	t.Helper()
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

// endingActionDecoder ends a session while a registration is being validated, between the
// registration's session check and the resource it records.
type endingActionDecoder struct {
	*realActionDecoder
	during func()
}

func (k *endingActionDecoder) DecodeEditorActions(ctx context.Context, payload any) (json.RawMessage, error) {
	if during := k.during; during != nil {
		k.during = nil
		during()
	}
	return k.realActionDecoder.DecodeEditorActions(ctx, payload)
}

func runningActionSession(service *Service, plugin, id string) *BackendSession {
	session := &BackendSession{host: service.Host, PluginID: plugin, Session: pluginbackend.Session{ID: id}, functions: map[string]bool{"actions.collect": true}, waiters: map[string]chan core.BackendEvent{}, done: make(chan struct{}), changed: make(chan struct{}), ready: true}
	service.Host.mu.Lock()
	service.Host.sessions[plugin] = session
	service.Host.mu.Unlock()
	return session
}

func registerActionsAs(service *Service, workspace WorkspaceContext, plugin, sessionID string) *pluginhost.Failure {
	body := `{` + contextJSONOf(workspace) + `,"id":"actions","function":"actions.collect","selector":{"fileExtensions":["java"]}}`
	ctx := pluginhost.WithCaller(context.Background(), pluginhost.Caller{PluginID: plugin, SessionID: sessionID})
	_, refusal := service.HostServices.Respond(ctx, methodRegisterEditorActions, json.RawMessage(body))
	return refusal
}

func editorActionSessions(service *Service) []string {
	service.actions.mu.Lock()
	defer service.actions.mu.Unlock()
	var sessions []string
	for _, binding := range service.actions.list {
		sessions = append(sessions, binding.sessionID)
	}
	return sessions
}

func resourcesHeldBy(service *Service, sessionID string) int {
	service.resources.mu.Lock()
	defer service.resources.mu.Unlock()
	held := 0
	for _, resource := range service.resources.byID {
		if resource.sessionID == sessionID {
			held++
		}
	}
	return held
}

// A restarted backend registers the same ID again before the ended session's release ran. The old
// binding used to refuse it for good, so the file kept no run or debug actions until a restart.
func TestEditorActionRegistrationReplacesTheBindingOfAnEndedSession(t *testing.T) {
	service, workspace := openDecodedEditorService(t, &actionRefreshWorkbench{fakeWorkbench: &fakeWorkbench{}})
	runningActionSession(service, "a", "session-old")
	if refusal := registerActionsAs(service, workspace, "a", "session-old"); refusal != nil {
		t.Fatalf("first session: %+v", refusal)
	}
	runningActionSession(service, "a", "session-new")
	if refusal := registerActionsAs(service, workspace, "a", "session-new"); refusal != nil {
		t.Fatalf("restarted session refused: %+v", refusal)
	}
	if sessions := editorActionSessions(service); len(sessions) != 1 || sessions[0] != "session-new" {
		t.Fatalf("bindings belong to %v, want only the restarted session", sessions)
	}
	if held := resourcesHeldBy(service, "session-old"); held != 0 {
		t.Fatalf("the ended session still holds %d resources", held)
	}
	if refusal := registerActionsAs(service, workspace, "a", "session-new"); refusal == nil {
		t.Fatal("the running session registered the same ID twice")
	}
}

// A session that ends while its registration is validated must not leave the binding behind: its
// release ran before the registration recorded anything it could release.
func TestEditorActionRegistrationDuringSessionEndIsWithdrawn(t *testing.T) {
	kernel := &endingActionDecoder{realActionDecoder: &realActionDecoder{notifyKernel: &notifyKernel{}}}
	service, workspace := openEditorServiceWith(t, kernel, &actionRefreshWorkbench{fakeWorkbench: &fakeWorkbench{}})
	session := runningActionSession(service, "a", "session-a")
	kernel.during = func() {
		// The order serve uses: mark the session ended, then release what it holds.
		session.mu.Lock()
		session.ended = true
		session.mu.Unlock()
		service.resources.releaseSession("session-a")
	}
	if refusal := registerActionsAs(service, workspace, "a", "session-a"); refusal == nil {
		t.Fatal("an ended session's registration succeeded")
	}
	if sessions := editorActionSessions(service); len(sessions) != 0 {
		t.Fatalf("bindings of the ended session remain: %v", sessions)
	}
	if held := resourcesHeldBy(service, "session-a"); held != 0 {
		t.Fatalf("the ended session still holds %d resources", held)
	}
}
