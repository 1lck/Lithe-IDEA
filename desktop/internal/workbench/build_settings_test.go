package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestBuildExecutableUsesActualGlobalPluginSettingWithoutFallback(t *testing.T) {
	for _, mode := range []string{"configured", "missing-configured", "directory-configured", "invalid-stored-value"} {
		t.Run(mode, func(t *testing.T) {
			manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/build-systems/build-tool-path.plugin.json")
			if err != nil {
				t.Fatal(err)
			}
			preferences := t.TempDir()
			h := newHarness(t, &testKernel{Client: core.NewClient()})
			h.app.store = store.At(preferences)
			h.open(t.TempDir())
			p := h.app.project
			bin := t.TempDir()
			fallback := filepath.Join(bin, "fixture-build")
			configured := filepath.Join(t.TempDir(), "selected")
			if runtime.GOOS == "windows" {
				fallback += ".exe"
				configured += ".exe"
			}
			copyTestBinary(t, fallback)
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			switch mode {
			case "configured":
				copyTestBinary(t, configured)
			case "directory-configured":
				if err := os.Mkdir(configured, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			var value any = configured
			if mode == "invalid-stored-value" {
				value = false
			}
			global, err := json.Marshal(map[string]any{"dev.lithe.fixture.build-tool-path": map[string]any{"toolPath": value}})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(preferences, "plugin-settings.json"), global, 0o600); err != nil {
				t.Fatal(err)
			}
			// A project may not replace a global-only executable selection.
			project, err := json.Marshal(map[string]any{"dev.lithe.fixture.build-tool-path": map[string]any{"toolPath": fallback}})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(filepath.Join(p.root, ".lithe"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(p.root, ".lithe", "plugin-settings.json"), project, 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			result, err := h.app.resolveBuildExecutable(ctx, p, buildInstance{BuildInstance: core.BuildInstance{Root: ".", BuildSystemID: "fixture"}, PluginID: "dev.lithe.fixture.build-tool-path", Manifest: manifest}, h.app.text.Build)
			if mode != "configured" {
				if err == nil {
					t.Fatalf("invalid explicit program fell back to %q", result.Executable)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if filepath.Clean(result.Executable) != filepath.Clean(configured) {
				t.Fatalf("actual global source was ignored: got %q want %q", result.Executable, configured)
			}
			if len(result.PathPrepend) != 1 || result.PathPrepend[0] != filepath.Dir(configured) {
				t.Fatalf("explicit tool directory missing from PATH: %+v", result.PathPrepend)
			}
		})
	}
}

var errProviderPreferencesCaptured = errors.New("test stopped at the provider plan boundary")

type providerPreferenceKernel struct {
	*testKernel
	directories core.PluginBackendDirectories
	plan        core.PluginBackendPlan
	uriCalls    int
}

func (k *providerPreferenceKernel) PlanPluginBuildProvider(ctx context.Context, manifest json.RawMessage, id string, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	k.directories = directories
	plan, err := k.Client.PlanPluginBuildProvider(ctx, manifest, id, directories)
	k.plan = plan
	if err != nil {
		return plan, err
	}
	return plan, errProviderPreferencesCaptured
}

func (k *providerPreferenceKernel) PluginDocumentURI(ctx context.Context, path, platform string) (string, error) {
	k.uriCalls++
	return k.Client.PluginDocumentURI(ctx, path, platform)
}

func TestBuildProviderUsesCapturedSettingsAndCoreWorkspaceURI(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	raw, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/build-providers/build-provider.plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["settings"] = 2
	manifest["settings"].([]any)[0].(map[string]any)["scope"] = "project"
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	kernel := &providerPreferenceKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	preferences := t.TempDir()
	h.app.store = store.At(preferences)
	service, err := pluginservice.Open(kernel, h.app.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	h.open(t.TempDir())
	p := h.app.project
	if err := os.WriteFile(filepath.Join(preferences, "plugin-settings.json"), []byte(`{"dev.lithe.fixture.build-provider":{"providerHeapMB":768}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(p.root, ".lithe"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p.root, ".lithe", "plugin-settings.json"), []byte(`{"dev.lithe.fixture.build-provider":{"providerHeapMB":1536}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = h.app.buildProvider(ctx, p, buildInstance{BuildInstance: core.BuildInstance{BuildSystemID: "gradle", Root: "."}, PluginID: "dev.lithe.fixture.build-provider", Version: "0.1.0", PackageDirectory: t.TempDir(), Manifest: encoded})
	if !errors.Is(err, errProviderPreferencesCaptured) {
		t.Fatalf("plan boundary: %v", err)
	}
	if string(kernel.directories.Settings["providerHeapMB"]) != "768" || string(kernel.directories.ProjectSettings["providerHeapMB"]) != "1536" {
		t.Errorf("provider layers missing: %+v", kernel.directories)
	}
	if len(kernel.plan.Launch.RuntimeArguments) != 1 || kernel.plan.Launch.RuntimeArguments[0] != "-Xmx1536m" {
		t.Errorf("Core did not resolve the actual project setting: %+v", kernel.plan.Launch)
	}
	if kernel.uriCalls != 1 {
		t.Errorf("provider workspace URI bypassed Core: calls=%d", kernel.uriCalls)
	}
}
