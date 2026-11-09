package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// This integration test uses an explicit, captured official plugin manifest,
// the selected native C compiler, the real adapter and the real Core engine.
func TestDebugRealLLDBLaunchTargetAndBreakpoints(t *testing.T) {
	manifestPath := os.Getenv("LITHE_TEST_DEBUG_PLUGIN_MANIFEST")
	if manifestPath == "" {
		t.Skip("set LITHE_TEST_DEBUG_PLUGIN_MANIFEST to run the real LLDB integration")
	}
	manifest, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	validationContext, cancelValidation := context.WithTimeout(context.Background(), 5*time.Second)
	_, validationErr := core.NewClient().ValidatePluginManifest(validationContext, manifest, map[string][]int{
		"debugAdapters": {1}, "serverProcess": {1}, "languages": {1}, "settings": {2},
	})
	cancelValidation()
	if validationErr != nil {
		t.Fatal(validationErr)
	}
	var identity struct {
		ID      string `json:"id"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(manifest, &identity); err != nil {
		t.Fatal(err)
	}
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, identity.ID, identity.Version)
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	installedManifest := filepath.Join(installed, "plugin.json")
	if err := os.WriteFile(installedManifest, manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	preferenceRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(preferenceRoot, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(preferenceRoot)
	if err := pluginstate.New(preferences).SetEnabled(identity.ID, true); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, PluginKernel: &testKernel{Client: core.NewClient()}, PluginRoot: pluginRoot, Store: preferences, Languages: []string{"en"}})
	root := t.TempDir()
	source := filepath.Join(root, "main.c")
	code := "#include <stdio.h>\nint main(void) {\n    int value = 41;\n    value += 1;\n    printf(\"debug-result=%d\\n\", value);\n    return value == 42 ? 0 : 1;\n}\n"
	if err := os.WriteFile(source, []byte(code), 0o600); err != nil {
		t.Fatal(err)
	}
	compiler, err := exec.LookPath("clang")
	if err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(root, "main")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	compilation, err := buildprocess.Start(ctx, buildprocess.Spec{Executable: compiler, Arguments: []string{"-g", "-O0", source, "-o", executable}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { compilation.Stop(); _ = compilation.Wait() })
	if err := compilation.Wait(); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.openFileAtPosition(p, source, 3, 0)
	h.settle()
	h.app.toggleBreakpoint(p)
	capture := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = capture
	h.app.startDebug(p)
	defer func() {
		t.Logf("debug state=%s status=%s failure=%s output=%v frames=%v", p.debug.state, p.debug.status, p.debug.failure, p.debug.output, p.debug.frames)
	}()
	awaitStateWithin(t, h, 15*time.Second, "real LLDB breakpoint and main frame", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("real LLDB launch failed: %s; output=%v", p.debug.failure, p.debug.output)
		}
		return p.debug.state == "paused" && len(p.debug.frames) > 0
	})
	if frame := p.debug.frames[0]; !strings.Contains(frame.Name, "main") || frame.SourcePath != source || frame.Line != 4 {
		t.Fatalf("real main breakpoint = %+v", frame)
	}
	select {
	case configuration := <-capture.configurations:
		if configuration.Arguments["program"] != executable || configuration.Arguments["cwd"] != root || configuration.Arguments["stopOnEntry"] != false {
			t.Fatalf("real launch configuration = %+v", configuration)
		}
	default:
		t.Fatal("the real DAP launch was not captured")
	}
	h.app.continueDebug(p)
	awaitStateWithin(t, h, 10*time.Second, "real debuggee exit and native cleanup", func() bool { return p.debug.session == nil })
	h.settle()
	after, err := os.ReadFile(installedManifest)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, manifest) {
		t.Fatal("debug launch changed installed plugin resources")
	}
}
