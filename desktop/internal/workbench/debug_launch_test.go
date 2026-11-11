package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
	definition["launch"] = []string{"${executable}", "${runtimeArguments}", "${entry}", "${arguments}"}
	manifest["toolDefinitions"] = []any{definition}
	manifest["requiresTools"] = []string{toolID}
	requires := manifest["requires"].(map[string]any)
	requires["serverProcess"], requires["toolDefinitions"], requires["executableResolution"], requires["debugAdapters"] = 4, 1, 2, 2
	declared := manifest["debugAdapters"].([]any)[0].(map[string]any)
	declared["configurations"].(map[string]any)["launch"].(map[string]any)["targetBindings"] = map[string]any{"args": "target.arguments", "env": "target.environment"}
	declared["launch"].(map[string]any)["process"].(map[string]any)["launch"] = map[string]any{"kind": "runtime", "tool": toolID, "entry": "adapter-entry", "runtimeArguments": []string{"--runtime"}}
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
	runtime := filepath.Join(adapter.Directory, debugFixtureProgramName())
	home := adapter.Directory
	h.app.toolchainResolve = func(_ context.Context, root, directory, tool, minimum string) (core.ToolchainSelection, error) {
		if root != p.root || directory != "." || tool != toolID {
			t.Fatalf("wrong runtime selection: %s %s %s", root, directory, tool)
		}
		return core.ToolchainSelection{Executable: runtime, Home: &home, Environment: map[string]string{"VM_HOME": home}}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p.root, "", 1, "unavailable")
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"--runtime", entry, "-test.run=^TestDebugAdapterRunner$"}
	if plan.Executable != runtime || !reflect.DeepEqual(plan.Arguments, expected) || plan.Environment["VM_HOME"] != home {
		t.Fatalf("tool definition launch = %+v, arguments want %v", plan, expected)
	}
}

func debugAdapterWithProgramSetting(t *testing.T, adapter debugAdapter, candidates []string) debugAdapter {
	t.Helper()
	var manifest map[string]any
	if err := json.Unmarshal(adapter.Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["settings"] = 2
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
	plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p.root, "", 1, "unavailable")
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
			plan, err := h.app.prepareDebugLaunch(ctx, debugStart{adapter: adapter, request: "launch"}, filepath.Join(t.TempDir(), "state"), p.root, "", 1, "unavailable")
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
