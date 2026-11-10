package pluginbackend

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// fakeKernel records what the runner asked Core to do.
type fakeKernel struct {
	plan             core.PluginBackendPlan
	planErr          error
	started          core.PluginBackendStarted
	startErr         error
	started_         core.PluginBackendStart
	events           [][]core.BackendEvent
	answeredMu       sync.Mutex
	answered         []answeredRequest
	stopErr          error
	destroyErr       error
	stopped          bool
	destroyed        bool
	semanticRequests []core.PluginSemanticRequest
	semanticErr      error
	operationID      string
	// planLanguageID records the language the runner asked Core to plan, and
	// startedRole records which start entry point it chose.
	planLanguageID        string
	startedLanguageServer bool
	buildRequests         []core.PluginBuildProviderRequest
	cancelled             bool
	functionCalls         []functionCall
}

type answeredRequest struct {
	session   string
	requestID string
	result    json.RawMessage
	failure   *core.PluginHostFailure
}

func (k *fakeKernel) PlanPluginBackend(context.Context, json.RawMessage, core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	return k.plan, k.planErr
}

func (k *fakeKernel) PlanPluginLanguageServer(_ context.Context, _ json.RawMessage, languageID string, _ core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	k.planLanguageID = languageID
	return k.plan, k.planErr
}

func (k *fakeKernel) PlanPluginBuildProvider(context.Context, json.RawMessage, string, core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	return k.plan, k.planErr
}

func (k *fakeKernel) StartPluginBackend(_ context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error) {
	k.started_ = request
	return k.started, k.startErr
}

func (k *fakeKernel) StartPluginLanguageServer(_ context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error) {
	k.started_ = request
	k.startedLanguageServer = true
	return k.started, k.startErr
}

func (k *fakeKernel) WaitBackendEvents(context.Context, string, int) ([]core.BackendEvent, error) {
	if len(k.events) == 0 {
		return nil, nil
	}
	batch := k.events[0]
	k.events = k.events[1:]
	return batch, nil
}

func (k *fakeKernel) StopPluginBackend(context.Context, string) error {
	k.stopped = true
	return k.stopErr
}

func (k *fakeKernel) DestroyPluginBackend(context.Context, string) error {
	k.destroyed = true
	return k.destroyErr
}

func (k *fakeKernel) RespondPluginHostRequest(_ context.Context, session, requestID string, result json.RawMessage, failure *core.PluginHostFailure) error {
	k.answeredMu.Lock()
	defer k.answeredMu.Unlock()
	k.answered = append(k.answered, answeredRequest{session: session, requestID: requestID, result: result, failure: failure})
	return nil
}

func (k *fakeKernel) RequestPluginSemantics(_ context.Context, request core.PluginSemanticRequest) (string, error) {
	if k.semanticErr != nil {
		return "", k.semanticErr
	}
	k.semanticRequests = append(k.semanticRequests, request)
	return k.operationID, nil
}

func (k *fakeKernel) RequestPluginBuild(_ context.Context, request core.PluginBuildProviderRequest) (string, error) {
	k.buildRequests = append(k.buildRequests, request)
	return k.operationID, nil
}

func (k *fakeKernel) CancelPluginOperation(context.Context, string, string) error {
	k.cancelled = true
	return nil
}

// backendPackage creates a package holding an executable and a data file.
func backendPackage(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range map[string]string{"bin/server": "binary", "lib/data.js": "code"} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// The production Windows adapter validates a native image even when the
	// process transport is fake. Reuse the already built test executable.
	if runtime.GOOS == "windows" {
		current, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		image, err := os.ReadFile(current)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "bin", "server"), image, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(filepath.Join(root, "bin", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

// packagedPlan is a plan that starts the package's own program.
func packagedPlan() core.PluginBackendPlan {
	plan := core.PluginBackendPlan{}
	plan.Launch.Kind = pluginhost.LaunchPackaged
	plan.Launch.Path = "bin/server"
	plan.RequiredPackagePaths = []string{"lib/data.js"}
	plan.Arguments = []string{"--stdio"}
	plan.InitializationOptions = json.RawMessage(`{"a":1}`)
	return plan
}

// startRequest is a valid request for the given package.
func startRequest(root string) StartRequest {
	return StartRequest{
		Manifest:         json.RawMessage(`{"id":"example","version":"1.0.0"}`),
		PackageDirectory: root,
		PluginID:         "example",
		ProviderID:       "example/provider",
		StateDirectory:   filepath.Join(root, "state"),
		Architecture:     "arm64",
		RootURI:          "file:///workspace",
		WorkingDirectory: "/workspace",
	}
}

// echoServices registers one host method that answers a fixed result.
func echoServices(t *testing.T) *pluginhost.Services {
	t.Helper()
	services := pluginhost.NewServices()
	if err := services.Register(pluginhost.MethodPrefix+"workspace/stat", func(context.Context, json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
		return json.RawMessage(`{"kind":"file"}`), nil
	}); err != nil {
		t.Fatal(err)
	}
	return services
}

func TestStartVerifiesThePlanAndStartsTheProcess(t *testing.T) {
	root := backendPackage(t)
	plan := packagedPlan()
	plan.Backend.HostServices = []string{pluginhost.MethodPrefix + "workspace/stat", pluginhost.MethodPrefix + "editor/applyEdits"}
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	runner := New(kernel, echoServices(t))

	session, err := runner.Start(context.Background(), startRequest(root))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if session.ID != "session-1" || session.PluginID != "example" || session.ProviderID != "example/provider" {
		t.Fatalf("session = %+v", session)
	}
	if want := filepath.Join(root, "bin", "server"); kernel.started_.ExecutablePath != want {
		t.Fatalf("executable = %q, want %q", kernel.started_.ExecutablePath, want)
	}
	if len(kernel.started_.HostServices) != 1 || kernel.started_.HostServices[0] != pluginhost.MethodPrefix+"workspace/stat" {
		t.Fatalf("host services = %v", kernel.started_.HostServices)
	}
	if string(kernel.started_.InitializationOptions) != `{"a":1}` {
		t.Fatalf("initialization options = %s", kernel.started_.InitializationOptions)
	}
	if kernel.started_.RootURI != "file:///workspace" {
		t.Fatalf("root uri = %v", kernel.started_.RootURI)
	}
	if len(kernel.started_.Arguments) != 1 || kernel.started_.Arguments[0] != "--stdio" {
		t.Fatalf("arguments = %v", kernel.started_.Arguments)
	}
}

func TestStartRefusesAnUnverifiedProgram(t *testing.T) {
	root := backendPackage(t)
	plan := packagedPlan()
	plan.Launch.Path = "bin/absent"
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	if _, err := New(kernel, nil).Start(context.Background(), startRequest(root)); !errors.Is(err, pluginhost.ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
	if kernel.started_.ExecutablePath != "" {
		t.Fatal("the process was started despite a refused plan")
	}
}

func TestStartRefusesAnUnusableRequest(t *testing.T) {
	root := backendPackage(t)
	kernel := &fakeKernel{plan: packagedPlan()}
	cases := map[string]func(*StartRequest){
		"no manifest":    func(r *StartRequest) { r.Manifest = nil },
		"relative root":  func(r *StartRequest) { r.PackageDirectory = "relative" },
		"no plugin ID":   func(r *StartRequest) { r.PluginID = "" },
		"no provider":    func(r *StartRequest) { r.ProviderID = "" },
		"no state":       func(r *StartRequest) { r.StateDirectory = "" },
		"relative state": func(r *StartRequest) { r.StateDirectory = "state" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			request := startRequest(root)
			mutate(&request)
			if _, err := New(kernel, nil).Start(context.Background(), request); !errors.Is(err, ErrRequest) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestStartRefusesWithoutKernel(t *testing.T) {
	runner := New(nil, nil)
	if _, err := runner.Start(context.Background(), StartRequest{}); err == nil {
		t.Fatal("a runner without a kernel started something")
	}
}

func TestStopStopsAndDisposes(t *testing.T) {
	kernel := &fakeKernel{}
	if err := New(kernel, nil).Stop(context.Background(), Session{ID: "session-1"}); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if !kernel.stopped || !kernel.destroyed {
		t.Fatalf("stopped = %v, destroyed = %v", kernel.stopped, kernel.destroyed)
	}
}

func TestStopDisposesEvenWhenShutdownFails(t *testing.T) {
	refusal := errors.New("shutdown refused")
	kernel := &fakeKernel{stopErr: refusal}
	err := New(kernel, nil).Stop(context.Background(), Session{ID: "session-1"})
	if !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
	if !kernel.destroyed {
		t.Fatal("the session was not disposed")
	}
}

func TestStopRefusesEmptySession(t *testing.T) {
	if err := New(&fakeKernel{}, nil).Stop(context.Background(), Session{}); !errors.Is(err, ErrNoSession) {
		t.Fatalf("err = %v", err)
	}
}

func TestServeAnswersHostRequestsAndStopsAtExit(t *testing.T) {
	kernel := &fakeKernel{events: [][]core.BackendEvent{
		{{Type: EventHostRequest, Method: pluginhost.MethodPrefix + "workspace/stat", Result: json.RawMessage(`{"hostRequestID":"req-1","service":"lithe/host/workspace/stat","params":{}}`)}},
		{{Type: EventHostRequest, Method: pluginhost.MethodPrefix + "editor/applyEdits", Result: json.RawMessage(`{"hostRequestID":"req-2","params":{}}`)}},
		{{Type: EventExit}},
	}}
	if err := New(kernel, echoServices(t)).Serve(context.Background(), Session{ID: "session-1"}, nil); err != nil {
		t.Fatalf("serve: %v", err)
	}
	if len(kernel.answered) != 2 {
		t.Fatalf("answered = %+v", kernel.answered)
	}
	// Requests are answered concurrently, so order them by identifier.
	sort.Slice(kernel.answered, func(i, j int) bool { return kernel.answered[i].requestID < kernel.answered[j].requestID })
	first := kernel.answered[0]
	if first.requestID != "req-1" || first.session != "session-1" {
		t.Fatalf("first = %+v", first)
	}
	if string(first.result) != `{"kind":"file"}` {
		t.Fatalf("first result = %s", first.result)
	}
	if first.failure != nil {
		t.Fatalf("first failure = %+v", first.failure)
	}
	second := kernel.answered[1]
	if second.failure == nil || second.failure.Code != pluginhost.CodeMethodNotDeclared {
		t.Fatalf("second = %+v", second)
	}
	if second.result != nil {
		t.Fatalf("a refused request returned a result: %s", second.result)
	}
}

func TestServeRefusesRequestsWithoutIdentity(t *testing.T) {
	kernel := &fakeKernel{events: [][]core.BackendEvent{
		{{Type: EventHostRequest, Method: pluginhost.MethodPrefix + "workspace/stat", Result: json.RawMessage(`{"params":{}}`)}},
	}}
	if err := New(kernel, echoServices(t)).Serve(context.Background(), Session{ID: "session-1"}, nil); err == nil {
		t.Fatal("a host request without an identifier was answered")
	}
}

func TestServeStopsWhenTheContextEnds(t *testing.T) {
	kernel := &fakeKernel{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := New(kernel, echoServices(t)).Serve(ctx, Session{ID: "session-1"}, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
}

func TestRequestFillsTheSessionAndReturnsTheOperation(t *testing.T) {
	kernel := &fakeKernel{operationID: "operation-7"}
	runner := New(kernel, echoServices(t))
	position := core.PluginDocumentPosition{Line: 4, UTF16Column: 9}
	operation, err := runner.Request(context.Background(), Session{ID: "session-1"}, core.PluginSemanticRequest{
		Operation: "definition",
		URI:       "file:///workspace/A.java",
		Position:  &position,
	})
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if operation != "operation-7" {
		t.Fatalf("operation = %q", operation)
	}
	if len(kernel.semanticRequests) != 1 {
		t.Fatalf("requests = %+v", kernel.semanticRequests)
	}
	sent := kernel.semanticRequests[0]
	// The caller does not know Core's session identity, so the runner fills it.
	if sent.SessionID != "session-1" || sent.Operation != "definition" {
		t.Fatalf("request = %+v", sent)
	}
	if sent.Position == nil || sent.Position.Line != 4 || sent.Position.UTF16Column != 9 {
		t.Fatalf("position = %+v", sent.Position)
	}
}

func TestRequestRefusesAnIncompleteRequest(t *testing.T) {
	runner := New(&fakeKernel{}, echoServices(t))
	if _, err := runner.Request(context.Background(), Session{}, core.PluginSemanticRequest{Operation: "definition"}); !errors.Is(err, ErrNoSession) {
		t.Fatalf("err = %v", err)
	}
	if _, err := runner.Request(context.Background(), Session{ID: "session-1"}, core.PluginSemanticRequest{}); !errors.Is(err, ErrRequest) {
		t.Fatalf("err = %v", err)
	}
	if _, err := New(nil, nil).Request(context.Background(), Session{ID: "session-1"}, core.PluginSemanticRequest{Operation: "definition"}); err == nil {
		t.Fatal("a runner without a kernel submitted a request")
	}
}

func TestRequestPropagatesCoreErrors(t *testing.T) {
	refusal := errors.New("plugin.lsp.requestRefused")
	runner := New(&fakeKernel{semanticErr: refusal}, echoServices(t))
	if _, err := runner.Request(context.Background(), Session{ID: "session-1"}, core.PluginSemanticRequest{Operation: "hover"}); !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
}

func TestStartResolvesASystemCommand(t *testing.T) {
	root := backendPackage(t)
	plan := core.PluginBackendPlan{}
	plan.Launch.Kind = pluginhost.LaunchSystemCommand
	plan.Launch.Commands = []string{"missing", "gopls"}
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	runner := New(kernel, echoServices(t))
	runner.lookup = func(name string) (string, error) {
		if name == "gopls" {
			return "/opt/gopls", nil
		}
		return "", errors.New("not found")
	}
	if _, err := runner.Start(context.Background(), startRequest(root)); err != nil {
		t.Fatalf("start: %v", err)
	}
	if kernel.started_.ExecutablePath != "/opt/gopls" {
		t.Fatalf("executable = %q", kernel.started_.ExecutablePath)
	}
}

func TestStartRefusesAnUnavailableSystemCommand(t *testing.T) {
	root := backendPackage(t)
	plan := core.PluginBackendPlan{}
	plan.Launch.Kind = pluginhost.LaunchSystemCommand
	plan.Launch.Commands = []string{"missing"}
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	runner := New(kernel, echoServices(t))
	runner.lookup = func(string) (string, error) { return "", errors.New("not found") }
	if _, err := runner.Start(context.Background(), startRequest(root)); !errors.Is(err, pluginhost.ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
	if kernel.started_.ExecutablePath != "" {
		t.Fatal("a process was started for an unavailable command")
	}
}

func TestArgumentsComposition(t *testing.T) {
	packaged := core.PluginBackendPlan{}
	packaged.Launch.Kind = pluginhost.LaunchPackaged
	packaged.Launch.Path = "bin/server"
	packaged.Arguments = []string{"--stdio"}
	if got := Arguments(packaged, ""); len(got) != 1 || got[0] != "--stdio" {
		t.Fatalf("packaged arguments = %v", got)
	}

	runtime := core.PluginBackendPlan{}
	runtime.Launch.Kind = pluginhost.LaunchRuntime
	runtime.Launch.PackagedRuntime = "bin/runtime"
	runtime.Launch.Entry = "lib/main.js"
	runtime.Launch.RuntimeArguments = []string{"--inspect"}
	runtime.Arguments = []string{"--stdio"}
	// The entry that is passed is the resolved one, not the plan's relative path.
	want := []string{"--inspect", "/package/lib/main.js", "--stdio"}
	got := Arguments(runtime, "/package/lib/main.js")
	if len(got) != len(want) {
		t.Fatalf("runtime arguments = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("runtime arguments = %v", got)
		}
	}
}

func TestStartUsesTheVerifiedRuntime(t *testing.T) {
	root := backendPackage(t)
	if err := os.Chmod(filepath.Join(root, "bin", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	plan := core.PluginBackendPlan{}
	plan.Launch.Kind = pluginhost.LaunchRuntime
	plan.Launch.PackagedRuntime = "bin/server"
	plan.Launch.Entry = "lib/data.js"
	plan.Launch.RuntimeArguments = []string{"--inspect"}
	plan.Arguments = []string{"--stdio"}
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	session, err := New(kernel, echoServices(t)).Start(context.Background(), startRequest(root))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if session.ID != "session-1" {
		t.Fatalf("session = %+v", session)
	}
	// A runtime launch must not start with an empty executable path.
	if want := filepath.Join(root, "bin", "server"); kernel.started_.ExecutablePath != want {
		t.Fatalf("executable = %q, want %q", kernel.started_.ExecutablePath, want)
	}
	want := []string{"--inspect", filepath.Join(root, "lib", "data.js"), "--stdio"}
	got := kernel.started_.Arguments
	if len(got) != len(want) {
		t.Fatalf("arguments = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("arguments = %v", got)
		}
	}
}

// A language server uses the language-specific planner and the language_server
// role; a plugin backend keeps the backend plan and role.
func TestStartUsesLanguageServerPlanAndRole(t *testing.T) {
	root := backendPackage(t)
	plan := packagedPlan()
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "session-1"}}
	request := startRequest(root)
	request.ProviderID = "example/language-server"
	request.LanguageID = "java"
	if _, err := New(kernel, echoServices(t)).Start(context.Background(), request); err != nil {
		t.Fatalf("start: %v", err)
	}
	if kernel.planLanguageID != "java" {
		t.Fatalf("planned language = %q", kernel.planLanguageID)
	}
	if !kernel.startedLanguageServer {
		t.Fatal("the runner used the plugin backend start entry point")
	}
}

func TestLanguageServerStartPreservesCoreWorkspaceConfiguration(t *testing.T) {
	// Read a real wire-shaped plan so the test also catches a missing bridge field.
	var plan core.PluginBackendPlan
	if err := json.Unmarshal([]byte(`{"launch":{"kind":"systemCommand","commands":["fixture-server"]},"arguments":[],"initializationOptions":{"mode":"fixture"},"workspaceConfiguration":{"fixture":{"enabled":true,"checks":["lint"]}}}`), &plan); err != nil {
		t.Fatal(err)
	}
	kernel := &fakeKernel{plan: plan, started: core.PluginBackendStarted{SessionID: "settings-session"}}
	runner := New(kernel, nil)
	// The fake Core only records start; no process is spawned. The native
	// executable belongs to this test invocation and is available on every OS.
	runner.lookup = func(string) (string, error) { return os.Executable() }
	request := startRequest(t.TempDir())
	request.LanguageID = "fixture"
	if _, err := runner.Start(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	wire, err := json.Marshal(kernel.started_)
	if err != nil {
		t.Fatal(err)
	}
	var actual map[string]json.RawMessage
	if err := json.Unmarshal(wire, &actual); err != nil {
		t.Fatal(err)
	}
	if string(actual["workspaceConfiguration"]) != `{"fixture":{"enabled":true,"checks":["lint"]}}` {
		t.Fatalf("Core workspace configuration disappeared before start: %s", wire)
	}
}

type functionCall struct {
	session, operation, plugin, function string
	params                               json.RawMessage
}

func (k *fakeKernel) InvokePluginFunction(_ context.Context, session, operation, plugin, function string, params json.RawMessage) (string, error) {
	k.functionCalls = append(k.functionCalls, functionCall{session, operation, plugin, function, append(json.RawMessage(nil), params...)})
	return k.operationID, k.semanticErr
}

func TestFunctionRequestUsesRunningSessionOwner(t *testing.T) {
	kernel := &fakeKernel{operationID: "operation-function"}
	runner := New(kernel, echoServices(t))
	result, err := runner.RequestFunction(context.Background(), Session{ID: "session-function", PluginID: "dev.example.owner"}, "requested-operation", "cache.refresh", json.RawMessage(`{}`))
	if err != nil || result != "operation-function" {
		t.Fatalf("function request: %q %v", result, err)
	}
	if len(kernel.functionCalls) != 1 {
		t.Fatalf("calls: %+v", kernel.functionCalls)
	}
	call := kernel.functionCalls[0]
	if call.session != "session-function" || call.plugin != "dev.example.owner" || call.operation != "requested-operation" || call.function != "cache.refresh" || string(call.params) != "{}" {
		t.Fatalf("retargeted function: %+v", call)
	}
}

func TestFunctionRequestRejectsUnownedSessionAndPreservesCoreFailure(t *testing.T) {
	kernel := &fakeKernel{semanticErr: errors.New("fixture Core refusal")}
	runner := New(kernel, echoServices(t))
	for _, session := range []Session{{}, {ID: "session"}, {PluginID: "dev.example.owner"}} {
		if _, err := runner.RequestFunction(context.Background(), session, "operation", "cache.refresh", nil); !errors.Is(err, ErrNoSession) {
			t.Fatalf("unowned session: %v", err)
		}
	}
	if len(kernel.functionCalls) != 0 {
		t.Fatal("unowned session reached Core")
	}
	_, err := runner.RequestFunction(context.Background(), Session{ID: "session", PluginID: "dev.example.owner"}, "operation", "cache.refresh", nil)
	if !errors.Is(err, kernel.semanticErr) {
		t.Fatalf("Core failure lost: %v", err)
	}
}

func (k *fakeKernel) InvokePluginFunctionInContext(context.Context, string, string, string, string, json.RawMessage, json.RawMessage, int) (string, error) {
	return "", errors.New("fixture kernel does not serve plugin functions")
}

func (k *fakeKernel) SendPluginHostNotification(context.Context, string, string, json.RawMessage) (bool, error) {
	return false, nil
}

func (k *fakeKernel) PluginServerRequest(context.Context, string, string, string, string, string, json.RawMessage, int) (string, error) {
	return "", errors.New("fixture kernel does not forward language-server requests")
}

func (k *fakeKernel) PluginServerNotify(context.Context, string, string, string, string, json.RawMessage) (bool, error) {
	return false, nil
}
