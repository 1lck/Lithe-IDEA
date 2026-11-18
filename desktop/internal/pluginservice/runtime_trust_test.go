package pluginservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

const runtimeFixtureTool = "dev.lithe.test.managed-environment:worker"

func runtimeFixtureCommand() string {
	if runtime.GOOS == "windows" {
		return "managed-fixture-tool.exe"
	}
	return "managed-fixture-tool"
}

// The version probe is the test binary itself, so this boundary test requires no
// installed interpreter. The child records its execution before printing a version.
func TestMain(m *testing.M) {
	executable, err := os.Executable()
	if err == nil && filepath.Base(executable) == runtimeFixtureCommand() && len(os.Args) == 2 && os.Args[1] == "--version" {
		if err := os.WriteFile(filepath.Join(filepath.Dir(executable), "probe-ran"), []byte("ran"), 0o600); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("ManagedFixture 1.0")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func runtimeToolFixture(t *testing.T) (json.RawMessage, string) {
	t.Helper()
	manifest, _, packageRoot := runtimeFixture(t)
	var value map[string]any
	if err := json.Unmarshal(manifest, &value); err != nil {
		t.Fatal(err)
	}
	value["requires"].(map[string]any)["toolDefinitions"] = 0
	value["requiresTools"] = []string{runtimeFixtureTool}
	value["toolDefinitions"] = []any{map[string]any{
		"id": runtimeFixtureTool, "displayName": "Managed fixture tool",
		"executableLayouts": []any{map[string]any{"path": "bin/" + runtimeFixtureCommand()}},
		"executables": []any{
			map[string]any{"id": "global", "kind": "setting", "settingID": "executable", "layer": "global"},
			map[string]any{"id": "shell", "kind": "command", "command": runtimeFixtureCommand()},
			map[string]any{"id": "installed", "kind": "toolchain", "scope": "installed"},
		},
		"version":  map[string]any{"arguments": []string{"--version"}, "pattern": `ManagedFixture (\d+(?:\.\d+)*)`},
		"commands": []string{runtimeFixtureCommand()},
		"exports":  []any{}, "pathPrepend": []string{},
		"launch": []string{"${executable}", "${arguments}"},
	}}
	managed := value["managedRuntimes"].(map[string]any)
	dependencies := managed["dependencies"].([]any)[:1]
	dependency := dependencies[0].(map[string]any)
	dependency["tool"] = runtimeFixtureTool
	dependency["artifacts"].([]any)[0].(map[string]any)["executable"] = "bin/" + runtimeFixtureCommand()
	managed["dependencies"] = dependencies
	manifest, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageRoot, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	return manifest, packageRoot
}

func runtimeToolHome(t *testing.T, home, packageRoot string) string {
	t.Helper()
	executable := filepath.Join(home, "bin", runtimeFixtureCommand())
	if err := os.MkdirAll(filepath.Dir(executable), 0o700); err != nil {
		t.Fatal(err)
	}
	image, err := os.ReadFile(filepath.Join(packageRoot, "bin", "resolver"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(executable, image, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "payload"), []byte("usable"), 0o600); err != nil {
		t.Fatal(err)
	}
	return executable
}

func runtimeTrustService(t *testing.T, external string) (*Service, *runtimeResolverKernel, *store.Store) {
	t.Helper()
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), external: map[string]string{"alpha": external}}
	preferences := store.At(t.TempDir())
	service, err := Open(kernel, preferences, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Contexts.CloseAll)
	return service, kernel, preferences
}

func TestManagedRuntimeToolsDoNotProbeOpenWorkspaces(t *testing.T) {
	for _, source := range []string{"path", "global-symlink"} {
		for _, owner := range []string{"current", "other-workbench"} {
			t.Run(source+"/"+owner, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				defer cancel()
				manifest, packageRoot := runtimeToolFixture(t)
				project := t.TempDir()
				home := filepath.Join(project, "local-tool")
				executable := runtimeToolHome(t, home, packageRoot)
				service, kernel, preferences := runtimeTrustService(t, "")
				contexts := service.Contexts
				if owner == "other-workbench" {
					other, err := OpenAnother(kernel, preferences, service.Root)
					if err != nil {
						t.Fatal(err)
					}
					contexts = other.Contexts
					t.Cleanup(contexts.CloseAll)
				}
				contexts.Open(project)
				t.Setenv("PATH", t.TempDir())
				if source == "path" {
					t.Setenv("PATH", filepath.Dir(executable))
				} else {
					alias := filepath.Join(t.TempDir(), "registered-tool")
					if err := os.Symlink(home, alias); err != nil {
						if runtime.GOOS == "windows" {
							t.Skipf("symlinks unavailable: %v", err)
						}
						t.Fatal(err)
					}
					change, err := kernel.EditToolchainCatalog(ctx, nil, toolchain.PlatformName(runtime.GOOS), []core.ToolchainCatalogEdit{{Tool: runtimeFixtureTool, Homes: []string{alias}, DefaultHome: &alias}})
					if err != nil || change.Document == nil {
						t.Fatalf("catalog fixture: %+v, %v", change, err)
					}
					catalog := filepath.Join(preferences.Dir(), "toolchains", "global.json")
					if err := os.MkdirAll(filepath.Dir(catalog), 0o700); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(catalog, []byte(*change.Document), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				plan, err := kernel.PlanManagedRuntimes(ctx, manifest, core.ManagedRuntimePlatform{OS: toolchain.PlatformName(runtime.GOOS), Arch: core.PluginArchitecture()})
				if err != nil {
					t.Fatal(err)
				}
				tools, err := service.runtimeTools(ctx, manifest, plan, service.Contexts.workspaceRoots())
				if _, probeErr := os.Stat(filepath.Join(filepath.Dir(executable), "probe-ran")); !errors.Is(probeErr, os.ErrNotExist) {
					t.Errorf("workspace tool ran a version probe: %v", probeErr)
				}
				if tools[runtimeFixtureTool].Executable != "" {
					t.Errorf("workspace executable escaped into runtime facts: %+v", tools)
				}
				if source == "global-symlink" {
					var unavailable *toolchain.UnavailableError
					if !errors.As(err, &unavailable) || !unavailable.Terminal {
						t.Errorf("explicit workspace selection must fail without fallback: %v", err)
					}
				} else if err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestManagedRuntimeHookCannotReturnOpenWorkspaceTool(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	manifest, packageRoot := runtimeToolFixture(t)
	project := t.TempDir()
	home := filepath.Join(project, "hook-tool")
	executable := runtimeToolHome(t, home, packageRoot)
	service, kernel, preferences := runtimeTrustService(t, home)
	other, err := OpenAnother(kernel, preferences, service.Root)
	if err != nil {
		t.Fatal(err)
	}
	other.Contexts.Open(project)
	t.Cleanup(other.Contexts.CloseAll)
	t.Setenv("PATH", t.TempDir())
	environment, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	var unavailable *toolchain.UnavailableError
	if !errors.As(err, &unavailable) || !unavailable.Terminal {
		t.Errorf("hook returned a project executable without terminal rejection: environment=%+v error=%v", environment, err)
	}
	if _, probeErr := os.Stat(filepath.Join(filepath.Dir(executable), "probe-ran")); !errors.Is(probeErr, os.ErrNotExist) {
		t.Errorf("hook's workspace executable ran before rejection: %v", probeErr)
	}
}

func TestManagedRuntimeBoundToolValidationIsReadOnly(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	manifest, packageRoot := runtimeToolFixture(t)
	home := t.TempDir()
	executable := runtimeToolHome(t, home, packageRoot)
	service, _, preferences := runtimeTrustService(t, home)
	project := t.TempDir()
	service.Contexts.Open(project)
	t.Setenv("PATH", t.TempDir())
	projectPins := filepath.Join(project, ".lithe", "toolchains.json")
	catalog := filepath.Join(preferences.Dir(), "toolchains", "global.json")
	sources := map[string][]byte{
		projectPins: []byte(`{"version":1,"toolchains":{"dev.lithe.test.project:compiler":{"home":"project-choice"}}}`),
		catalog:     []byte(`{"version":1,"tools":{}}`),
	}
	for path, body := range sources {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	environment, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	want, canonicalErr := filepath.EvalSymlinks(executable)
	if err != nil || canonicalErr != nil || filepath.Clean(environment.Tools[runtimeFixtureTool].Path) != filepath.Clean(want) {
		t.Fatalf("external runtime = %+v, error=%v, canonical=%v", environment, err, canonicalErr)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(executable), "probe-ran")); err != nil {
		t.Fatalf("external bound tool was never version-checked: %v", err)
	}
	for path, before := range sources {
		after, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(before, after) {
			t.Fatalf("runtime validation changed toolchain choices at %s: %v", path, err)
		}
	}
}

func TestManagedRuntimeBoundExecutableMustMatchToolSelection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	manifest, packageRoot := runtimeToolFixture(t)
	home := t.TempDir()
	executable := runtimeToolHome(t, home, packageRoot)
	other := filepath.Join(home, "bin", "other-tool")
	image, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, image, 0o755); err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(manifest, &value); err != nil {
		t.Fatal(err)
	}
	dependency := value["managedRuntimes"].(map[string]any)["dependencies"].([]any)[0].(map[string]any)
	dependency["artifacts"].([]any)[0].(map[string]any)["executable"] = "bin/other-tool"
	manifest, err = json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	service, _, _ := runtimeTrustService(t, home)
	t.Setenv("PATH", t.TempDir())
	_, err = service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	if !errors.Is(err, ErrRuntimeIncomplete) {
		t.Fatalf("bound executable differed from the Core-selected file: %v", err)
	}
}

func TestManagedRuntimeBoundToolDoesNotRetainWorkspaceSymlink(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	manifest, packageRoot := runtimeToolFixture(t)
	project, home := t.TempDir(), t.TempDir()
	executable := runtimeToolHome(t, home, packageRoot)
	alias := filepath.Join(t.TempDir(), "workspace")
	if err := os.Symlink(project, alias); err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("symlinks unavailable: %v", err)
		}
		t.Fatal(err)
	}
	link := filepath.Join(alias, "tool")
	if err := os.Symlink(home, link); err != nil {
		t.Fatal(err)
	}
	service, _, _ := runtimeTrustService(t, link)
	service.Contexts.Open(alias)
	t.Setenv("PATH", t.TempDir())
	environment, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(environment.Tools[runtimeFixtureTool].Path) != filepath.Clean(want) || filepath.Clean(environment.Facts[runtimeFixtureTool].Executable) != filepath.Clean(want) {
		t.Errorf("bound runtime retained a mutable workspace alias: %+v", environment)
	}
	wantHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(environment.Runtimes["alpha"].Home) != filepath.Clean(wantHome) || filepath.Clean(environment.Facts[runtimeFixtureTool].Home) != filepath.Clean(wantHome) {
		t.Errorf("runtime launch facts retained a mutable workspace home: %+v", environment)
	}
	otherHome := t.TempDir()
	runtimeToolHome(t, otherHome, packageRoot)
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(otherHome, link); err != nil {
		t.Fatal(err)
	}
	approved, err := os.Stat(want)
	if err != nil {
		t.Fatal(err)
	}
	bound, err := os.Stat(environment.Tools[runtimeFixtureTool].Path)
	if err != nil || !os.SameFile(approved, bound) {
		t.Fatalf("changing a workspace symlink redirected the approved tool: %v", err)
	}
	fromHome, err := os.Stat(filepath.Join(environment.Runtimes["alpha"].Home, "bin", runtimeFixtureCommand()))
	if err != nil || !os.SameFile(approved, fromHome) {
		t.Fatalf("changing a workspace symlink redirected the approved runtime home: %v", err)
	}
}
