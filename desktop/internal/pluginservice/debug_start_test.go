package pluginservice

import (
	"context"
	"encoding/json"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const debugStartFixturePlugin = "dev.lithe.fixture.debug-adapter-features"

// debugStartHarness installs the contract's debug-adapter-features plugin, which
// holds the debug.start permission, over the real Core's decoding.
func debugStartHarness(t *testing.T) (*Service, string) {
	t.Helper()
	preferences := store.At(t.TempDir())
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, debugStartFixturePlugin, "0.1.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/debug-adapters/debug-adapter-features.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(manifest, &document); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled(debugStartFixturePlugin, true); err != nil {
		t.Fatal(err)
	}
	service, err := Open(&runKernel{client: core.NewClient()}, preferences, pluginRoot)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	service.Contexts.Open(root)
	t.Cleanup(func() { service.Contexts.CloseAll() })
	return service, root
}

func debugStartParams(t *testing.T, service *Service, root string, extra map[string]any) string {
	t.Helper()
	workspace, ok := service.Contexts.ByPath(root)
	if !ok {
		t.Fatal("the workspace context is not open")
	}
	params := map[string]any{
		"context": workspace.ContextRef, "label": "Debug main.script", "adapter": "script", "request": "launch",
		"configuration": map[string]any{"program": "main.script"},
	}
	for key, value := range extra {
		params[key] = value
	}
	data, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestDebugStartHandsTheValidatedStartToTheWindowAndStopsBySession(t *testing.T) {
	service, root := debugStartHarness(t)
	var mu sync.Mutex
	var got DebugSessionRequest
	var stopped []string
	service.Runs.StartDebugSession = func(_ context.Context, request DebugSessionRequest) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		got = request
		return "session-1", nil
	}
	service.Runs.StopDebugSession = func(id string) {
		mu.Lock()
		defer mu.Unlock()
		stopped = append(stopped, id)
	}

	result, refusal := respond(t, service, debugStartFixturePlugin, "debug/start", debugStartParams(t, service, root, nil))
	if refusal != nil {
		t.Fatalf("debug/start refused: %+v", refusal)
	}
	var reply struct {
		SessionID string `json:"sessionID"`
	}
	if err := json.Unmarshal(result, &reply); err != nil || reply.SessionID != "session-1" {
		t.Fatalf("reply = %s (%v)", result, err)
	}
	mu.Lock()
	if got.AdapterID != debugStartFixturePlugin+"/script" || got.Request != "launch" || got.Label != "Debug main.script" ||
		got.PluginID != debugStartFixturePlugin || got.Configuration["program"] != "main.script" || got.WorkspaceRoot != root {
		t.Fatalf("the window received %+v", got)
	}
	mu.Unlock()

	// A foreign plugin cannot stop the session; the owner can, once.
	if _, refusal := respond(t, service, "other.plugin", "run/stop", `{"sessionID":"session-1"}`); refusal != nil {
		t.Fatalf("a foreign stop was refused instead of ignored: %+v", refusal)
	}
	mu.Lock()
	if len(stopped) != 0 {
		t.Fatalf("a foreign plugin stopped the session: %v", stopped)
	}
	mu.Unlock()
	for range 2 {
		if _, refusal := respond(t, service, debugStartFixturePlugin, "run/stop", `{"sessionID":"session-1"}`); refusal != nil {
			t.Fatalf("run/stop: %+v", refusal)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(stopped) != 1 || stopped[0] != "session-1" {
		t.Fatalf("stopped = %v, want one stop of session-1", stopped)
	}
}

func TestDebugStartRefusalsComeFromCore(t *testing.T) {
	service, root := debugStartHarness(t)
	service.Runs.StartDebugSession = func(context.Context, DebugSessionRequest) (string, error) {
		t.Fatal("a refused start reached the window")
		return "", nil
	}
	for name, extra := range map[string]map[string]any{
		"an adapter of another plugin": {"adapter": "org.example.other/script"},
		"an unknown adapter":           {"adapter": "missing"},
		"a reserved configuration key": {"configuration": map[string]any{"__pending": true}},
	} {
		_, refusal := respond(t, service, debugStartFixturePlugin, "debug/start", debugStartParams(t, service, root, extra))
		if refusal == nil || refusal.Code != "plugin.host.invalidParams" {
			t.Fatalf("%s: %+v, want invalidParams carrying Core's code", name, refusal)
		}
	}
}

func TestDebugStartWithoutAWindowIsUnavailable(t *testing.T) {
	service, root := debugStartHarness(t)
	_, refusal := respond(t, service, debugStartFixturePlugin, "debug/start", debugStartParams(t, service, root, nil))
	if refusal == nil || refusal.Code != "plugin.host.unavailable" {
		t.Fatalf("refusal = %+v, want unavailable", refusal)
	}
}
