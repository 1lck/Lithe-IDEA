package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
)

// countedDebugCreate observes whether native preparation reached the engine.
type countedDebugCreate struct {
	Kernel
	creates atomic.Int32
}

func (k *countedDebugCreate) CreateDebugSession(ctx context.Context, request core.DebugCreateSessionRequest) (core.DebugUpdate, error) {
	k.creates.Add(1)
	return k.Kernel.CreateDebugSession(ctx, request)
}

func TestDebugMissingTargetIsRejectedBeforeStartingTheAdapter(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	var manifest map[string]any
	if err := json.Unmarshal(p.debug.adapters[0].Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	adapter := manifest["debugAdapters"].([]any)[0].(map[string]any)
	adapter["configurations"].(map[string]any)["launch"].(map[string]any)["targetBindings"] = map[string]any{"program": "target.path"}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	p.debug.adapters[0].Manifest = data
	counted := &countedDebugCreate{Kernel: h.app.kernel}
	h.app.kernel = counted
	h.app.startDebug(p)
	session := p.debug.activeSession()
	awaitStateWithin(t, h, 5*time.Second, "missing target rejection", func() bool { return p.debug.activeSession() == nil && p.debug.failure != "" })
	if session.process.Load() != nil || counted.creates.Load() != 0 {
		t.Fatal("invalid target started an adapter or Core session")
	}
	h.settle()
	if session.stateDirectory != "" {
		if _, err := os.Stat(session.stateDirectory); !os.IsNotExist(err) {
			t.Fatalf("rejected launch retained owned scratch state: %v", err)
		}
	}
}

func TestDebugRuntimeArgumentsComeFromTheToolDefinition(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	runtimeName := "jre/bin/vm"
	if filepath.Ext(debugFixtureProgramName()) == ".exe" {
		runtimeName += ".exe"
	}
	executable := filepath.Join(home, runtimeName)
	if err := os.MkdirAll(filepath.Dir(executable), 0o700); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, executable)
	t.Setenv("FICTIONAL_VM_HOME", home)
	t.Setenv(syntheticWorkbenchInterpMarkerEnv, filepath.Join(home, "probe-marker"))
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	adapter := p.debug.adapters[0]
	var manifest map[string]any
	if err := json.Unmarshal(adapter.Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	rawDefinition, err := os.ReadFile("../toolchain/testdata/runtime.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	var toolManifest map[string]any
	if err := json.Unmarshal(rawDefinition, &toolManifest); err != nil {
		t.Fatal(err)
	}
	definition := toolManifest["toolDefinitions"].([]any)[0].(map[string]any)
	toolID := adapter.PluginID + ":vm"
	definition["id"] = toolID
	definition["launch"] = []string{"${executable}", "${runtimeArguments}", "${arguments}", "${entry}"}
	definition["executableLayouts"].([]any)[0].(map[string]any)["path"] = runtimeName
	definition["executables"].([]any)[0].(map[string]any)["path"] = runtimeName
	definition["version"] = map[string]any{"arguments": []string{"--version"}, "pattern": "SyntheticInterp ([0-9.]+)"}
	manifest["toolDefinitions"] = []any{definition}
	manifest["requiresTools"] = []string{toolID}
	manifest["permissions"] = []string{"debug.launch", "run.start", "backend.launch"}
	manifest["activationEvents"] = []string{"onDebug:fixture", "onWorkspaceOpen"}
	manifest["backend"] = map[string]any{"launch": map[string]string{"kind": "packaged", "path": debugFixtureProgramName()}}
	requires := manifest["requires"].(map[string]any)
	requires["toolDefinitions"], requires["backend"] = 0, 0
	declared := manifest["debugAdapters"].([]any)[0].(map[string]any)
	declared["configurations"].(map[string]any)["launch"].(map[string]any)["targetBindings"] = map[string]any{"args": "target.arguments", "env": "target.environment"}
	declared["launch"].(map[string]any)["process"].(map[string]any)["launch"] = map[string]any{"kind": "runtime", "tool": toolID, "entry": "adapter-entry", "runtimeArguments": []string{"-test.count=1"}}
	adapter.Manifest, err = json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(adapter.Directory, "plugin.json"), adapter.Manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(adapter.Directory, "adapter-entry")
	if err := os.WriteFile(entry, []byte("fixture entry"), 0o600); err != nil {
		t.Fatal(err)
	}
	// An incomplete installation has a version directory but no readable manifest.
	const brokenID = "dev.lithe.test.unreadable"
	broken := filepath.Join(filepath.Dir(filepath.Dir(adapter.Directory)), brokenID, "1.0.0")
	if err := os.MkdirAll(broken, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(h.app.store).SetEnabled(brokenID, true); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p, "", 1, "unavailable")
	if err != nil {
		var r *core.MarketplaceRejection
		if errors.As(err, &r) {
			t.Fatalf("prepare: %s: %v", r.Field, err)
		}
		t.Fatal(err)
	}
	expected := []string{"-test.count=1", "-test.run=^TestDebugAdapterRunner$", entry}
	// Core may return slash-separated paths on Windows as well.
	if filepath.Clean(plan.Executable) != filepath.Clean(executable) {
		t.Fatalf("executable = %q, want %q", plan.Executable, executable)
	}
	if !reflect.DeepEqual(plan.Arguments, expected) {
		t.Fatalf("arguments = %q, want %q", plan.Arguments, expected)
	}
	if got := plan.Environment["FICTIONAL_VM_HOME"]; filepath.Clean(got) != filepath.Clean(home) {
		t.Fatalf("FICTIONAL_VM_HOME = %q, want %q", got, home)
	}
	manifests, discoveryErr := h.app.toolchainManifests(ctx)
	if len(manifests) == 0 || discoveryErr == nil {
		t.Fatalf("expected a partially readable catalog, got %d manifests and %v", len(manifests), discoveryErr)
	}
	verifyPartialCatalogRun(t, h, p, ctx, adapter, toolID, entry)
	if err := os.WriteFile(filepath.Join(p.root, "debug.marker"), []byte("debug"), 0o600); err != nil {
		t.Fatal(err)
	}
	p.debug.adapters[0] = adapter
	h.app.startDebug(p)
	awaitStateWithin(t, h, 30*time.Second, "runtime adapter frames", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("runtime adapter: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	h.app.stopDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "runtime adapter stopped", func() bool { return p.debug.activeSession() == nil })
}

// verifyPartialCatalogRun exercises the runtime entry planner and run/start with the real installed registry.
func verifyPartialCatalogRun(t *testing.T, h *harness, p *project, ctx context.Context, adapter debugAdapter, toolID, entry string) {
	t.Helper()
	run, err := h.app.resolveBackendToolEntry(ctx, adapter.PluginID, p.root, pluginbackend.ToolEntryLaunch{Tool: toolID, Entry: entry, Arguments: []string{"-test.list=^TestDebugAdapterRunner$"}})
	if err != nil {
		t.Fatal(err)
	}
	workspace, ok := h.app.plugins.Contexts.ByPath(p.root)
	if !ok {
		t.Fatal("workspace context not open")
	}
	params, err := json.Marshal(map[string]any{
		"context": workspace.ContextRef, "label": "Partial catalog runtime", "process": map[string]any{
			"executable": map[string]string{"kind": "tool", "tool": toolID}, "arguments": run.Arguments, "workingDirectory": ".", "environment": map[string]string{},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	caller := pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: adapter.PluginID, SessionID: "fixture-session"})
	reply, failure := h.app.plugins.HostServices.Respond(caller, pluginhost.MethodPrefix+"run/start", params)
	if failure != nil {
		t.Fatalf("run/start: %+v", failure)
	}
	var result struct{ RunID string }
	if err := json.Unmarshal(reply, &result); err != nil || result.RunID == "" {
		t.Fatalf("run/start response: %s, %v", reply, err)
	}
	awaitStateWithin(t, h, 15*time.Second, "run process output", func() bool {
		session := p.runEntry(result.RunID)
		return session != nil && !session.running && strings.Contains(session.output.all(), "TestDebugAdapterRunner")
	})
}

func debugAdapterWithProgramSetting(t *testing.T, adapter debugAdapter, candidates []string) debugAdapter {
	t.Helper()
	var manifest map[string]any
	if err := json.Unmarshal(adapter.Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["settings"] = 0
	manifest["settings"] = []any{map[string]any{"id": "program", "type": "file", "title": "Program", "default": "", "scope": "project", "effect": "nextRun"}}
	launch := manifest["debugAdapters"].([]any)[0].(map[string]any)["configurations"].(map[string]any)["launch"].(map[string]any)
	launch["executable"] = map[string]any{"setting": "program", "candidates": candidates}
	launch["targetBindings"] = map[string]any{"program": "target.executable"}
	var err error
	adapter.Manifest, err = json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return adapter
}

func TestDebugExecutableLookupSkipsNonFileCandidates(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	adapter := debugAdapterWithProgramSetting(t, p.debug.adapters[0], []string{"${workspaceFolder}/not-a-program", "${workspaceFolder}/build/program"})
	if err := os.MkdirAll(filepath.Join(p.root, "not-a-program"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(p.root, "build"), 0o700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(p.root, "build", "program")
	if debugFixtureProgramName() == "adapter.exe" {
		executable += ".exe"
	}
	copyTestBinary(t, executable)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p, "", 1, "unavailable")
	if err != nil {
		t.Fatal(err)
	}
	program, ok := plan.Configuration.Arguments["program"].(string)
	if !ok || filepath.Clean(program) != filepath.Clean(executable) {
		t.Fatalf("target = %+v", plan.Configuration)
	}
}

func TestDebugReadsProgramFromActualPluginSettingSources(t *testing.T) {
	for _, invalid := range []bool{false, true} {
		name := "project-override"
		if invalid {
			name = "invalid-override-does-not-fall-back"
		}
		t.Run(name, func(t *testing.T) {
			h := debugHarness(t)
			p := openDebugPanel(t, h, t.TempDir())
			adapter := debugAdapterWithProgramSetting(t, p.debug.adapters[0], []string{"${workspaceFolder}/automatic"})
			automatic, configured := filepath.Join(p.root, "automatic"), filepath.Join(p.root, "configured")
			if debugFixtureProgramName() == "adapter.exe" {
				automatic += ".exe"
				configured += ".exe"
			}
			copyTestBinary(t, automatic)
			if !invalid {
				copyTestBinary(t, configured)
			}
			// The global value and automatic candidate are both runnable. A
			// configured project value must win, and a bad one must fail.
			global, err := json.Marshal(map[string]any{adapter.PluginID: map[string]any{"program": automatic}})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(h.app.store.Dir(), "plugin-settings.json"), global, 0o600); err != nil {
				t.Fatal(err)
			}
			project, err := json.Marshal(map[string]any{adapter.PluginID: map[string]any{"program": configured}})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(p.root, ".lithe"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(p.root, ".lithe", "plugin-settings.json"), project, 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p, "", 1, "unavailable")
			if invalid {
				if err == nil {
					t.Fatalf("invalid configured program fell back: %+v", plan.Configuration)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			program, ok := plan.Configuration.Arguments["program"].(string)
			if !ok || filepath.Clean(program) != filepath.Clean(configured) {
				t.Fatalf("actual project source was ignored: %+v", plan.Configuration)
			}
		})
	}
}

func TestDebugRequiredDirectoriesCreateStateAndLogSlots(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	adapter := p.debug.adapters[0]
	var manifest map[string]any
	if err := json.Unmarshal(adapter.Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	process := manifest["debugAdapters"].([]any)[0].(map[string]any)["launch"].(map[string]any)["process"].(map[string]any)
	process["arguments"] = []any{"-test.run=^TestDebugAdapterRunner$", "--state=${stateDir}", "--workspace-state=${workspaceStateDir}", "--log-dir=${logDir}"}
	var err error
	adapter.Manifest, err = json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(adapter.Directory, "plugin.json"), adapter.Manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	logRoot := filepath.Join(t.TempDir(), "logs", "plugins", adapter.PluginID, "files")
	h.app.logSink = &pluginFilesLog{directory: logRoot}
	t.Cleanup(func() { h.app.logSink = nil })

	stateRoot := filepath.Join(t.TempDir(), "state")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, stateRoot, p, "", 1, "unavailable")
	if err != nil {
		t.Fatalf("prepareDebugLaunch failed for RequiredDirectories slots: %v", err)
	}
	for _, wantDir := range []string{stateRoot, filepath.Join(stateRoot, "workspace"), logRoot} {
		info, statErr := os.Stat(wantDir)
		if statErr != nil || !info.IsDir() {
			t.Fatalf("required directory %q not created: %v", wantDir, statErr)
		}
	}
	expected := []string{
		"-test.run=^TestDebugAdapterRunner$",
		"--state=" + stateRoot,
		"--workspace-state=" + filepath.Join(stateRoot, "workspace"),
		"--log-dir=" + logRoot,
	}
	if !reflect.DeepEqual(plan.Arguments, expected) {
		t.Fatalf("arguments = %v, want %v", plan.Arguments, expected)
	}
}
