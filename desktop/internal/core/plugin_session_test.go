package core

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

// Core rejects any launch architecture outside the contract's names, so an
// x86_64 host that sent Go's amd64 or the marketplace's x64 could start no
// plugin backend.
func TestPluginArchitectureUsesContractNames(t *testing.T) {
	for goarch, want := range map[string]string{"amd64": "x86_64", "arm64": "arm64"} {
		if got := pluginArchitecture(goarch); got != want {
			t.Errorf("pluginArchitecture(%q) = %q, want %q", goarch, got, want)
		}
	}
}

func TestPluginBackendPlanUsesCoreManifestAndCapabilities(t *testing.T) {
	manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/backend/backend.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	client, ctx := NewClient(), testContext(t)
	_, err = client.ValidatePluginManifest(ctx, manifest, nil)
	var rejection *MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.api.unsupported" {
		t.Fatalf("missing capabilities were accepted: %v", err)
	}
	validated, err := client.ValidatePluginManifest(ctx, manifest, map[string][]int{"backend": {1}, "serverProcess": {1}, "ui": {2}})
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	state := filepath.Join(root, "state")
	plan, err := client.PlanPluginBackend(ctx, validated, PluginBackendDirectories{PluginDirectory: root, StateDirectory: state, Architecture: "arm64"})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Launch.Kind != "packaged" || plan.Launch.Path != "bin/backend" || !reflect.DeepEqual(plan.Arguments, []string{"--state", state}) || !reflect.DeepEqual(plan.RequiredPackagePaths, []string{"bin/backend"}) {
		t.Fatalf("backend plan = %+v", plan)
	}
}

// The desktop editor consumes TextMate, so a pinned Core must validate the
// matching contract and reject the withdrawn Monarch capability version.
func TestPluginTextMateGrammarUsesPinnedCore(t *testing.T) {
	manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/languages/language-grammar.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	grammar, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/languages/grammars/http.tmLanguage.json")
	if err != nil {
		t.Fatal(err)
	}
	client, ctx := NewClient(), testContext(t)
	validated, err := client.ValidatePluginManifest(ctx, manifest, map[string][]int{"languages": {3}})
	if err != nil {
		t.Fatal(err)
	}
	language, err := client.DecodePluginGrammar(ctx, validated, "http", string(grammar))
	if err != nil {
		t.Fatal(err)
	}
	if language.ID != "http" || language.Grammar == nil || language.Grammar.Kind != "textmate" || language.Grammar.ScopeName != "source.http" || language.Grammar.Source != string(grammar) {
		t.Fatalf("unexpected grammar result: %+v", language)
	}
	parsed, err := textmate.ParseGrammar([]byte(language.Grammar.Source))
	if err != nil || parsed.ScopeName != language.Grammar.ScopeName {
		t.Fatalf("editor could not parse Core-validated grammar: scope=%v err=%v", parsed, err)
	}
	_, err = client.DecodePluginGrammar(ctx, validated, "http", "not JSON")
	var rejection *MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.grammar.invalid" {
		t.Fatalf("invalid grammar was not rejected: %v", err)
	}
	var legacy map[string]any
	if err := json.Unmarshal(manifest, &legacy); err != nil {
		t.Fatal(err)
	}
	legacy["requires"].(map[string]any)["languages"] = 2
	legacy["languages"].([]any)[0].(map[string]any)["grammar"].(map[string]any)["kind"] = "monarch"
	legacyJSON, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.ValidatePluginManifest(ctx, legacyJSON, map[string][]int{"languages": {2, 3}})
	if !errors.As(err, &rejection) || rejection.Code != "plugin.api.unsupported" {
		t.Fatalf("withdrawn Monarch capability was not rejected: %v", err)
	}
	delete(legacy["languages"].([]any)[0].(map[string]any), "grammar")
	legacy["requires"].(map[string]any)["languages"] = 3
	configOnly, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	language, err = client.DecodePluginGrammar(ctx, configOnly, "http", "")
	if err != nil || language.Grammar != nil || len(language.Configuration) == 0 || string(language.Configuration) == "null" {
		t.Fatalf("configuration-only language = %+v, err=%v", language, err)
	}
}

// Core's stop request starts shutdown; destruction is valid only after it
// becomes terminal. Wait for events rather than racing immediate destruction.
func stopTestPluginBackend(ctx context.Context, client *Client, session string) error {
	if err := client.StopPluginBackend(ctx, session); err != nil {
		return err
	}
	for {
		err := client.DestroyPluginBackend(ctx, session)
		if err == nil {
			return nil
		}
		var coreErr *Error
		if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest || coreErr.Message != "A running language-server session cannot be destroyed." {
			return err
		}
		if _, err := client.WaitBackendEvents(ctx, session, 250); err != nil {
			return err
		}
	}
}

// TestPluginBackendHelper is a real subprocess speaking only the small part
// of JSON-RPC needed to exercise Core's plugin session. It is never a product
// backend; the parent launches this test binary with a private environment.
func TestPluginBackendHelper(t *testing.T) {
	if os.Getenv("LITHE_TEST_PLUGIN_BACKEND") != "1" {
		return
	}
	reader := bufio.NewReader(os.Stdin)
	var pending json.RawMessage
	var hostPending json.RawMessage
	configurationQueries := 0
	send := func(message any) {
		body, err := json.Marshal(message)
		if err != nil {
			os.Exit(7)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(8)
		}
	}
	reply := func(id json.RawMessage, result any) {
		send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(2)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(3)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(4)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(5)
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(body, &request) != nil {
			os.Exit(6)
		}
		if os.Getenv("LITHE_TEST_PLUGIN_CONFIGURATION") == "1" {
			if request.Method == "workspace/didChangeConfiguration" {
				configurationQueries++
				send(map[string]any{"jsonrpc": "2.0", "id": fmt.Sprintf("configuration-%d", configurationQueries), "method": "workspace/configuration", "params": map[string]any{"items": []any{map[string]any{"section": "elixirLS"}}}})
				continue
			}
			if request.Method == "" && strings.HasPrefix(string(request.ID), `"configuration-`) {
				send(map[string]any{"jsonrpc": "2.0", "method": "window/logMessage", "params": map[string]any{"type": 3, "message": "configuration:" + string(request.Result)}})
				continue
			}
		}
		if request.Method == "" && string(request.ID) == `"host-read"` && len(hostPending) != 0 {
			reply(hostPending, request.Result)
			hostPending = nil
			continue
		}
		if request.Method == "exit" {
			os.Exit(0)
		}
		if request.Method == "$/cancelRequest" && len(pending) != 0 {
			reply(pending, map[string]any{"answer": "late"})
			pending = nil
		}
		if len(request.ID) == 0 {
			continue
		}
		var result any
		switch request.Method {
		case "initialize":
			result = map[string]any{"capabilities": map[string]any{"experimental": map[string]any{"litheFunctions": map[string]any{"version": 2, "functions": []any{map[string]any{"id": "snapshot.refresh"}}}}}}
		case "lithe/function/invoke":
			var parameters struct {
				Params struct {
					Input int `json:"input"`
				} `json:"params"`
			}
			if json.Unmarshal(request.Params, &parameters) != nil {
				os.Exit(9)
			}
			if parameters.Params.Input == 9 {
				pending = append(pending[:0], request.ID...)
				continue
			}
			if parameters.Params.Input == 7 {
				hostPending = append(hostPending[:0], request.ID...)
				send(map[string]any{"jsonrpc": "2.0", "id": "host-read", "method": "lithe/host/credentials/get", "params": map[string]any{"key": "test.key"}})
				continue
			}
			result = map[string]any{"answer": "from backend"}
		case "shutdown":
			result = nil
		default:
			result = nil
		}
		reply(request.ID, result)
	}
}

func TestPluginBackendCoreSessionInvokesFunctionAndCleansUp(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	fixture, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/backend/backend.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(fixture, &manifest); err != nil {
		t.Fatal(err)
	}
	backend := manifest["backend"].(map[string]any)
	backend["launch"].(map[string]any)["path"] = filepath.Base(executable)
	backend["arguments"] = []string{"-test.run=^TestPluginBackendHelper$"}
	input, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	validated, err := client.ValidatePluginManifest(ctx, input, map[string][]int{"backend": {1}, "serverProcess": {1}, "ui": {2}})
	if err != nil {
		t.Fatal(err)
	}
	plan, err := client.PlanPluginBackend(ctx, validated, PluginBackendDirectories{PluginDirectory: filepath.Dir(executable), StateDirectory: root, Architecture: PluginArchitecture()})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Launch.Kind != "packaged" || plan.Launch.Path != filepath.Base(executable) {
		t.Fatalf("unexpected launch plan: %+v", plan)
	}
	started, err := client.StartPluginBackend(ctx, PluginBackendStart{
		ProviderID: "test-backend", PluginID: "dev.lithe.fixture.backend", ExecutablePath: filepath.Join(filepath.Dir(executable), plan.Launch.Path),
		Arguments: plan.Arguments, Environment: map[string]string{"LITHE_TEST_PLUGIN_BACKEND": "1"},
		HostServices: []string{"credentials"},
		RootURI:      NativeDocumentPath{Path: root, Platform: "auto"}, WorkingDirectory: root,
		InitializeTimeoutMilliseconds: 5000, RequestTimeoutMilliseconds: 5000, ShutdownTimeoutMilliseconds: 3000,
	})
	if err != nil {
		t.Fatal(err)
	}
	cleaned := false
	t.Cleanup(func() {
		if cleaned {
			return
		}
		cleanup, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := stopTestPluginBackend(cleanup, client, started.SessionID); err != nil {
			t.Errorf("stop and destroy backend: %v", err)
		}
	})
	if started.SessionID == "" || started.ProcessID == nil {
		t.Fatalf("invalid start response: %+v", started)
	}
	var lastSequence uint64
	waitFor := func(predicate func(BackendEvent) bool) BackendEvent {
		t.Helper()
		for {
			events, err := client.WaitBackendEvents(ctx, started.SessionID, 1000)
			if err != nil {
				t.Fatal(err)
			}
			for _, event := range events {
				if event.Sequence <= lastSequence || event.SessionID != started.SessionID {
					t.Fatalf("invalid event order or owner: %+v after %d", event, lastSequence)
				}
				lastSequence = event.Sequence
				if predicate(event) {
					return event
				}
			}
		}
	}
	waitFor(func(event BackendEvent) bool {
		return event.Type == "functionsChanged" && strings.Contains(string(event.Result), "snapshot.refresh")
	})
	candidates := []PluginFunctionProviderCandidate{{SessionID: started.SessionID, Version: "1.0.0"}}
	for _, scope := range []struct{ root, version, want string }{{root, "1.0.0", started.SessionID}, {t.TempDir(), "1.0.0", ""}, {root, "9.0.0", ""}} {
		selected, selectErr := client.SelectPluginFunctionProvider(ctx, "dev.lithe.fixture.backend", scope.version, "snapshot.refresh", scope.root, candidates)
		if selectErr != nil || selected != scope.want {
			t.Fatalf("function provider for %q version %q: %q %v", scope.root, scope.version, selected, selectErr)
		}
	}
	_, err = client.InvokePluginFunction(ctx, started.SessionID, "", "dev.example.other", "snapshot.refresh", nil)
	denied := requireCode(t, err, CodePermissionDenied)
	if denied.Details != "plugin.function.wrongPlugin" {
		t.Fatalf("wrong owner: %+v", denied)
	}
	operation, err := client.InvokePluginFunction(ctx, started.SessionID, "host-test-1", "dev.lithe.fixture.backend", "snapshot.refresh", json.RawMessage(`{"input":1}`))
	if err != nil || operation != "host-test-1" {
		t.Fatalf("invoke: %q, %v", operation, err)
	}
	completed := waitFor(func(event BackendEvent) bool {
		return event.Type == "requestCompleted" && event.OperationID == operation
	})
	if len(completed.Error) != 0 || !strings.Contains(string(completed.Result), "from backend") {
		t.Fatalf("function result: %+v", completed)
	}
	operation, err = client.InvokePluginFunction(ctx, started.SessionID, "host-service", "dev.lithe.fixture.backend", "snapshot.refresh", json.RawMessage(`{"input":7}`))
	if err != nil {
		t.Fatal(err)
	}
	hostRequest := waitFor(func(event BackendEvent) bool { return event.Type == "hostRequest" })
	var host struct {
		ID      string `json:"hostRequestID"`
		Service string `json:"service"`
	}
	if err := json.Unmarshal(hostRequest.Result, &host); err != nil || host.ID == "" || host.Service != "credentials" || hostRequest.Method != "lithe/host/credentials/get" {
		t.Fatalf("host request: %+v, %+v, %v", hostRequest, host, err)
	}
	if err := client.RespondPluginHostRequest(ctx, started.SessionID, host.ID, json.RawMessage(`{"value":1}`), &PluginHostFailure{Message: "failure"}); err == nil {
		t.Fatal("a response with both a result and an error was accepted")
	}
	if err := client.RespondPluginHostRequest(ctx, started.SessionID, host.ID, json.RawMessage(`{"secret":"fixture-only"}`), nil); err != nil {
		t.Fatal(err)
	}
	completed = waitFor(func(event BackendEvent) bool {
		return event.Type == "requestCompleted" && event.OperationID == operation
	})
	if len(completed.Error) != 0 || !strings.Contains(string(completed.Result), "fixture-only") {
		t.Fatalf("host service result: %+v", completed)
	}
	if err := client.RespondPluginHostRequest(ctx, started.SessionID, host.ID, nil, nil); err == nil {
		t.Fatal("Core accepted a second reply to the same host request")
	}
	operation, err = client.InvokePluginFunction(ctx, started.SessionID, "host-cancel", "dev.lithe.fixture.backend", "snapshot.refresh", json.RawMessage(`{"input":9}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := client.CancelPluginOperation(ctx, started.SessionID, operation); err != nil {
		t.Fatal(err)
	}
	cancelled := waitFor(func(event BackendEvent) bool {
		return event.Type == "requestCompleted" && event.OperationID == operation
	})
	if len(cancelled.Error) == 0 {
		t.Fatalf("cancellation did not produce a failure: %+v", cancelled)
	}
	operation, err = client.InvokePluginFunction(ctx, started.SessionID, "host-cancel", "dev.lithe.fixture.backend", "snapshot.refresh", json.RawMessage(`{"input":1}`))
	if err != nil {
		t.Fatal(err)
	}
	completed = waitFor(func(event BackendEvent) bool {
		return event.Type == "requestCompleted" && event.OperationID == operation
	})
	if len(completed.Error) != 0 || !strings.Contains(string(completed.Result), "from backend") {
		t.Fatalf("late reply contaminated reused operation ID: %+v", completed)
	}
	if err := stopTestPluginBackend(ctx, client, started.SessionID); err != nil {
		t.Fatal(err)
	}
	cleaned = true
	if _, err := client.WaitBackendEvents(ctx, started.SessionID, 1); err == nil {
		t.Fatal("destroyed session is still accessible")
	}
}

// Verify accepted and rejected architecture spellings through the real Core planner.
func TestPluginLaunchArchitectureAcceptsOnlyTheContractSpelling(t *testing.T) {
	manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/backend/backend.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	client, ctx := NewClient(), testContext(t)
	validated, err := client.ValidatePluginManifest(ctx, manifest, map[string][]int{"backend": {1}, "serverProcess": {1}, "ui": {2}})
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	directories := func(architecture string) PluginBackendDirectories {
		return PluginBackendDirectories{PluginDirectory: root, StateDirectory: filepath.Join(root, "state"), Architecture: architecture}
	}
	for _, architecture := range []string{"arm64", "x86_64"} {
		if _, err := client.PlanPluginBackend(ctx, validated, directories(architecture)); err != nil {
			t.Errorf("architecture %q was refused: %v", architecture, err)
		}
	}
	for _, architecture := range []string{"amd64", "x64", "sparc"} {
		_, err := client.PlanPluginBackend(ctx, validated, directories(architecture))
		var rejection *MarketplaceRejection
		if !errors.As(err, &rejection) || rejection.Code != "plugin.launch.invalidRequest" {
			t.Errorf("architecture %q returned %v, want plugin.launch.invalidRequest", architecture, err)
			continue
		}
		if !strings.Contains(rejection.Message, architecture) {
			t.Errorf("the refusal for %q does not name it: %q", architecture, rejection.Message)
		}
	}
}
