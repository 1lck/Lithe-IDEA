package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func openHostService(t *testing.T) *Service {
	t.Helper()
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return service
}

func callerContext(plugin string) context.Context {
	return pluginhost.WithCaller(context.Background(), pluginhost.Caller{PluginID: plugin, SessionID: "session-" + plugin})
}

func respond(t *testing.T, service *Service, plugin, method, params string) (json.RawMessage, *pluginhost.Failure) {
	t.Helper()
	return service.HostServices.Respond(callerContext(plugin), pluginhost.MethodPrefix+method, json.RawMessage(params))
}

func TestHostServicesGrantWhatIsServed(t *testing.T) {
	granted := pluginhost.GrantServices([]string{
		"workspace", "functions", "credentials", methodLSRequest, "lithe/host/run/start",
	}, openHostService(t).HostServices)
	want := []string{"workspace", "functions", methodLSRequest}
	if strings.Join(granted, ",") != strings.Join(want, ",") {
		t.Fatalf("granted = %v, want %v", granted, want)
	}
}

func TestWorkspaceContextsAreScopedToTheCallingPlugin(t *testing.T) {
	service := openHostService(t)
	root := t.TempDir()
	workspace := service.Contexts.Open(root)
	if again := service.Contexts.Open(root); again.ContextID != workspace.ContextID {
		t.Fatal("opening the same workspace twice made two contexts")
	}

	result, refusal := respond(t, service, "a", "workspace/listContexts", `{}`)
	if refusal != nil {
		t.Fatalf("listContexts: %+v", refusal)
	}
	var listed struct {
		Revision uint64 `json:"revision"`
		Contexts []struct {
			ContextID      string `json:"contextID"`
			StateDirectory string `json:"stateDirectory"`
			Folders        []struct {
				RootID string `json:"rootID"`
				Path   string `json:"path"`
			} `json:"folders"`
		} `json:"contexts"`
	}
	if err := json.Unmarshal(result, &listed); err != nil || len(listed.Contexts) != 1 {
		t.Fatalf("list = %s (%v)", result, err)
	}
	if listed.Contexts[0].StateDirectory != "" {
		t.Fatal("listing contexts created or revealed a state directory")
	}
	if entries, _ := os.ReadDir(filepath.Join(service.Root, pluginStateDirectory, "a")); len(entries) != 0 {
		t.Fatalf("listing left directories behind: %v", entries)
	}
	rootA := listed.Contexts[0].Folders[0].RootID

	other, _ := respond(t, service, "b", "workspace/listContexts", `{}`)
	if strings.Contains(string(other), rootA) {
		t.Fatal("two plugins saw the same root ID for one folder")
	}

	reference := `{"context":{"contextID":"` + workspace.ContextID + `","generation":1}}`
	result, refusal = respond(t, service, "a", "workspace/getContext", reference)
	if refusal != nil {
		t.Fatalf("getContext: %+v", refusal)
	}
	var detailed struct {
		StateDirectory string `json:"stateDirectory"`
	}
	_ = json.Unmarshal(result, &detailed)
	pluginRoot := filepath.Join(service.Root, pluginStateDirectory) + string(filepath.Separator)
	if !strings.HasPrefix(detailed.StateDirectory, pluginRoot) {
		t.Fatalf("state directory %q is outside the plugin storage %q", detailed.StateDirectory, pluginRoot)
	}
	if info, err := os.Stat(detailed.StateDirectory); err != nil || !info.IsDir() {
		t.Fatalf("getContext did not create the state directory: %v", err)
	}

	if result, refusal = respond(t, service, "a", "workspace/getFolders", reference); refusal != nil || !strings.Contains(string(result), root) {
		t.Fatalf("getFolders = %s, %+v", result, refusal)
	}

	stale := `{"context":{"contextID":"` + workspace.ContextID + `","generation":2}}`
	if _, refusal = respond(t, service, "a", "workspace/getContext", stale); refusal == nil || refusal.Code != "plugin.host.contextExpired" {
		t.Fatalf("a stale generation was served: %+v", refusal)
	}
	service.Contexts.Close(root)
	if _, refusal = respond(t, service, "a", "workspace/getFolders", reference); refusal == nil || refusal.Code != "plugin.host.contextExpired" {
		t.Fatalf("a closed context was served: %+v", refusal)
	}
}

func TestSubscriptionDisposeAcceptsAnyID(t *testing.T) {
	service := openHostService(t)
	if result, refusal := respond(t, service, "a", "subscriptions/dispose", `{"subscriptionID":"unknown"}`); refusal != nil || len(result) != 0 {
		t.Fatalf("dispose = %s, %+v", result, refusal)
	}
}

// languageKernel completes forwarded requests from a canned event.
type languageKernel struct {
	fakeKernel
	session *LanguageSession
	event   core.BackendEvent
	seen    []string
}

func (k *languageKernel) PluginServerRequest(_ context.Context, session, operation, plugin, server, method string, _ json.RawMessage, _ int) (string, error) {
	k.seen = append(k.seen, session+"|"+plugin+"|"+server+"|"+method)
	event := k.event
	event.OperationID = operation
	go k.session.deliver(event)
	return operation, nil
}

func TestLanguageServerRequestsReachTheOwnedSession(t *testing.T) {
	kernel := &languageKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workspace := service.Contexts.Open(t.TempDir())
	session := &LanguageSession{
		PluginID: "a", LanguageID: "java", ContextID: workspace.ContextID, ContextGeneration: workspace.Generation,
		Session: pluginbackend.Session{ID: "ls-1"},
	}
	service.registerLanguageSession(session)
	kernel.session = session
	reference := `"context":{"contextID":"` + workspace.ContextID + `","generation":1},"serverID":"java"`

	kernel.event = core.BackendEvent{Type: "requestCompleted", Result: json.RawMessage(`{"value":{"ok":true}}`)}
	result, refusal := respond(t, service, "a", "languageServer/request", `{`+reference+`,"method":"workspace/executeCommand"}`)
	if refusal != nil || string(result) != `{"value":{"ok":true}}` {
		t.Fatalf("request = %s, %+v", result, refusal)
	}
	if len(kernel.seen) != 1 || kernel.seen[0] != "ls-1|a|java|workspace/executeCommand" {
		t.Fatalf("seen = %v", kernel.seen)
	}

	kernel.event = core.BackendEvent{Type: "requestCompleted", Error: json.RawMessage(`{"code":"plugin.host.methodNotDeclared","message":"no","details":{"x":1}}`)}
	_, refusal = respond(t, service, "a", "languageServer/request", `{`+reference+`,"method":"textDocument/hover"}`)
	if refusal == nil || refusal.Code != "plugin.host.methodNotDeclared" || string(refusal.Details) != `{"x":1}` {
		t.Fatalf("Core's refusal was not relayed unchanged: %+v", refusal)
	}

	if _, refusal = respond(t, service, "b", "languageServer/request", `{`+reference+`,"method":"x"}`); refusal == nil || refusal.Code != "plugin.host.foreignContribution" {
		t.Fatalf("another plugin reached the server: %+v", refusal)
	}
	missing := strings.Replace(reference, `"serverID":"java"`, `"serverID":"kotlin"`, 1)
	if _, refusal = respond(t, service, "a", "languageServer/request", `{`+missing+`,"method":"x"}`); refusal == nil || refusal.Code != "plugin.host.languageServerUnavailable" {
		t.Fatalf("a missing server was served: %+v", refusal)
	}

	if result, refusal = respond(t, service, "a", "languageServer/setStatus", `{`+reference+`,"state":"preparing","message":"Importing"}`); refusal != nil || string(result) != `{}` {
		t.Fatalf("setStatus = %s, %+v", result, refusal)
	}
	if status := session.Status(); status.State != "preparing" || status.Message != "Importing" {
		t.Fatalf("status = %+v", status)
	}

	// A stopped server fails the requests still waiting, like a crashed process.
	waiting := make(chan *pluginhost.Failure, 1)
	kernel.event = core.BackendEvent{}
	kernel.session = &LanguageSession{}
	go func() {
		_, failed := respond(t, service, "a", "languageServer/request", `{`+reference+`,"method":"slow"}`)
		waiting <- failed
	}()
	time.Sleep(50 * time.Millisecond)
	session.end()
	select {
	case failed := <-waiting:
		if failed == nil || failed.Code != "plugin.host.languageServerUnavailable" {
			t.Fatalf("a request survived the server: %+v", failed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a request kept waiting after the server stopped")
	}
}

func TestLanguageStateAndNotificationsReachTheBackend(t *testing.T) {
	kernel := &notifyKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	backend := &BackendSession{
		host: service.Host, PluginID: "a", ready: true,
		Session: pluginbackend.Session{ID: "backend-1", Granted: []string{methodLSRequest}},
		done:    make(chan struct{}), changed: make(chan struct{}),
	}
	service.Host.sessions["a"] = backend
	session := &LanguageSession{PluginID: "a", LanguageID: "java", ContextID: "w-1", ContextGeneration: 1, Generation: 3}

	service.observeLanguage(session, core.BackendEvent{Type: "stateChanged", State: "ready"})
	service.observeLanguage(session, core.BackendEvent{Type: "stateChanged", State: "ready"})
	service.observeLanguage(session, core.BackendEvent{Type: "pluginServerNotification", Result: json.RawMessage(`{"serverID":"java","method":"language/status","params":{"type":"Started"}}`)})
	service.observeLanguage(session, core.BackendEvent{Type: "stateChanged", State: "failed"})

	want := []string{
		`backend-1 lithe/host/languageServer/didChangeState {"context":{"contextID":"w-1","generation":1},"generation":3,"serverID":"java","state":"running"}`,
		`backend-1 lithe/host/languageServer/didReceiveNotification {"context":{"contextID":"w-1","generation":1},"generation":3,"method":"language/status","params":{"type":"Started"},"serverID":"java"}`,
		`backend-1 lithe/host/languageServer/didChangeState {"context":{"contextID":"w-1","generation":1},"generation":3,"serverID":"java","state":"crashed"}`,
	}
	if strings.Join(kernel.sent, "\n") != strings.Join(want, "\n") {
		t.Fatalf("sent:\n%s\nwant:\n%s", strings.Join(kernel.sent, "\n"), strings.Join(want, "\n"))
	}
}

type notifyKernel struct {
	fakeKernel
	sent []string
}

func (k *notifyKernel) SendPluginHostNotification(_ context.Context, session, method string, params json.RawMessage) (bool, error) {
	k.sent = append(k.sent, session+" "+method+" "+string(params))
	return true, nil
}

func TestBackendCallWaitsForTheFunctionAndItsCompletion(t *testing.T) {
	kernel := &callKernel{}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	backend := &BackendSession{
		host: service.Host, PluginID: "a",
		Session:   pluginbackend.Session{ID: "backend-1"},
		functions: map[string]bool{}, waiters: map[string]chan core.BackendEvent{},
		done: make(chan struct{}), changed: make(chan struct{}),
	}
	kernel.backend = backend

	type outcome struct {
		value json.RawMessage
		err   error
	}
	done := make(chan outcome, 1)
	go func() {
		value, err := backend.Call(context.Background(), "java.resolveLaunch", json.RawMessage(`{"resolveParams":{}}`), json.RawMessage(`{"contextID":"w-1","generation":1}`), time.Second)
		done <- outcome{value, err}
	}()
	select {
	case <-done:
		t.Fatal("the call ran before the backend was ready and had registered the function")
	case <-time.After(100 * time.Millisecond):
	}
	backend.observe(core.BackendEvent{Type: "stateChanged", State: "ready"})
	backend.observe(core.BackendEvent{Type: "functionsChanged", Result: json.RawMessage(`{"functions":["java.resolveLaunch"],"removed":[]}`)})
	select {
	case got := <-done:
		if got.err != nil || string(got.value) != `{"executable":{}}` {
			t.Fatalf("call = %s, %v", got.value, got.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the call never completed")
	}
	if kernel.context != `{"contextID":"w-1","generation":1}` {
		t.Fatalf("the call did not carry the workspace context: %s", kernel.context)
	}
}

type callKernel struct {
	fakeKernel
	backend *BackendSession
	context string
}

func (k *callKernel) InvokePluginFunctionInContext(_ context.Context, _, operation, _, _ string, _, workspaceContext json.RawMessage, _ int) (string, error) {
	k.context = string(workspaceContext)
	go k.backend.observe(core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: json.RawMessage(`{"value":{"executable":{}}}`)})
	return operation, nil
}
