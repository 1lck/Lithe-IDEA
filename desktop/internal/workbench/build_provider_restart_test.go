package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

const (
	restartFixtureID   = "dev.lithe.test.provider-tests"
	restartFixtureTool = restartFixtureID + ":runtime"
)

// providerSettingsManifest is the provider fixture with one global setting that its launch passes
// in initializationOptions, so each process records the value it started with.
func providerSettingsManifest(t *testing.T) string {
	t.Helper()
	var manifest map[string]any
	if err := json.Unmarshal([]byte(providerTestsManifest), &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["settings"] = 0
	manifest["settings"] = []any{map[string]any{
		"id": "providerHeapMB", "type": "integer", "title": "Provider memory",
		"default": 1024, "minimum": 256, "maximum": 8192,
	}}
	system := manifest["buildSystems"].([]any)[0].(map[string]any)
	system["provider"].(map[string]any)["initializationOptions"] = map[string]any{"heap": "${setting:providerHeapMB}"}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

// These providers actually launch through Core's runtime plan and the host's
// toolchain resolver. The packaged fixture remains independent of this source.
func providerToolchainManifest(t *testing.T) string {
	t.Helper()
	t.Setenv(syntheticWorkbenchInterpMarkerEnv, filepath.Join(t.TempDir(), "version-probed"))
	var manifest map[string]any
	if err := json.Unmarshal([]byte(providerSettingsManifest(t)), &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["requires"].(map[string]any)["toolDefinitions"] = 0
	manifest["requiresTools"] = []string{restartFixtureTool}
	manifest["toolDefinitions"] = []any{map[string]any{
		"id": restartFixtureTool, "displayName": "Fixture runtime",
		"executableLayouts": []any{map[string]string{"path": fixtureRuntimePath()}},
		"executables": []any{
			map[string]string{"id": "shell", "kind": "command", "command": "lithe-test-provider-runtime"},
			map[string]string{"id": "installed", "kind": "toolchain", "scope": "installed"},
		},
		"commands": []string{"lithe-test-provider-runtime"},
		"version": map[string]any{
			"arguments": []string{"--version"},
			"pattern":   `SyntheticInterp (\d+(?:\.\d+)*)`,
		},
		"launch": []string{"${executable}", "${runtimeArguments}", "${arguments}", "${entry}"},
	}}
	system := manifest["buildSystems"].([]any)[0].(map[string]any)
	system["provider"].(map[string]any)["launch"] = map[string]string{
		"kind": "runtime", "tool": restartFixtureTool, "entry": "plugin.json",
	}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func fixtureRuntimePath() string {
	if runtime.GOOS == "windows" {
		return "bin/fixture-runtime.exe"
	}
	return "bin/fixture-runtime"
}

func newFixtureRuntime(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	path := filepath.Join(home, filepath.FromSlash(fixtureRuntimePath()))
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, path)
	return filepath.ToSlash(home)
}

// openProviderSettingsFixture opens a workspace the settings fixture provider serves.
func openProviderSettingsFixture(t *testing.T, h *harness, markers ...string) *project {
	t.Helper()
	root := t.TempDir()
	for _, marker := range append([]string{"fixture.marker", "initialize.marker"}, markers...) {
		if err := os.WriteFile(filepath.Join(root, marker), []byte("fixture\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	return h.app.project
}

// settingsFixtureInstance is the build instance of the settings fixture.
func settingsFixtureInstance(h *harness, manifest string) buildInstance {
	return buildInstance{
		BuildInstance: core.BuildInstance{BuildSystemID: "fixture-provider-tests", Root: "."},
		PluginID:      restartFixtureID, Version: "1.0.0",
		PackageDirectory: filepath.Join(h.app.plugins.Root, restartFixtureID, "1.0.0"),
		Manifest:         json.RawMessage(manifest),
	}
}

// requestProvider asks for the instance's provider the way a build request does, away from the
// window thread, and returns the client it got.
func requestProvider(t *testing.T, h *harness, p *project, instance buildInstance) *buildprovider.Client {
	t.Helper()
	var client *buildprovider.Client
	var failure error
	done := false
	h.app.background(p, 90*time.Second, func(ctx context.Context) func(*App) {
		started, err := h.app.buildProvider(ctx, p, instance)
		return func(*App) { client, failure, done = started, err, true }
	})
	awaitStateWithin(t, h, 90*time.Second, "the provider request", func() bool { return done })
	if failure != nil {
		t.Fatalf("start the provider: %v", failure)
	}
	return client
}

// saveProviderHeap saves the fixture's setting as the settings window does and applies the
// effects the save reports.
func saveProviderHeap(t *testing.T, h *harness, instance buildInstance, heap int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	settings := pluginsettings.New(h.app.kernel, h.store.Dir())
	snapshot, err := settings.Load(ctx, instance.Manifest, h.app.project.root)
	if err != nil {
		t.Fatalf("load the plugin settings: %v", err)
	}
	value, err := json.Marshal(heap)
	if err != nil {
		t.Fatal(err)
	}
	result, err := settings.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "providerHeapMB", Value: value}}, nil)
	if err != nil || !result.Committed {
		t.Fatalf("save the plugin settings: committed=%v err=%v", result.Committed, err)
	}
	h.app.post(func(a *App) {
		a.applyPluginSettingsEffects(core.PluginSettingsOwner{PluginID: instance.PluginID, Version: instance.Version}, result.Effects)
	})
	h.settle()
}

// providerStarts is what each start of the fixture provider got as initializationOptions.
func providerStarts(t *testing.T, p *project) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(p.root, "initialize.log"))
	if err != nil {
		t.Fatalf("read the provider starts: %v", err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

// The contract restarts a build provider on the next request after its plugin's settings changed,
// so its launch reflects the current values. The host used to keep the process it started first,
// and a run after the user chose a setting still saw the old value (#2142).
func TestBuildProviderRestartsOnTheNextRequestAfterItsSettingsChanged(t *testing.T) {
	manifest := providerSettingsManifest(t)
	h := providerTestsHarnessWith(t, manifest)
	p := openProviderSettingsFixture(t, h)
	instance := settingsFixtureInstance(h, manifest)

	first := requestProvider(t, h, p, instance)
	if again := requestProvider(t, h, p, instance); again != first {
		t.Fatal("a request with unchanged settings started another provider")
	}
	saveProviderHeap(t, h, instance, 2048)
	second := requestProvider(t, h, p, instance)
	if second == first {
		t.Fatal("the request after the settings changed reused the provider started with the old values")
	}
	awaitStateWithin(t, h, 30*time.Second, "the replaced provider's exit", first.Closed)
	starts := providerStarts(t, p)
	if len(starts) != 2 || !strings.Contains(starts[0], "1024") || !strings.Contains(starts[1], "2048") {
		t.Fatalf("provider starts = %q, want the default then the saved value", starts)
	}
	if again := requestProvider(t, h, p, instance); again != second {
		t.Fatal("the restarted provider was replaced again without a settings change")
	}
}

// A request the replaced provider is already serving keeps running to its own answer: the host
// closes that provider only after the request finished, never by failing it.
func TestReplacedBuildProviderFinishesTheRequestItHas(t *testing.T) {
	manifest := providerSettingsManifest(t)
	h := providerTestsHarnessWith(t, manifest)
	p := openProviderSettingsFixture(t, h, "block.marker")
	instance := settingsFixtureInstance(h, manifest)

	first := requestProvider(t, h, p, instance)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := first.WaitReady(ctx); err != nil {
		t.Fatalf("the provider never became ready: %v", err)
	}
	// block.marker makes the fixture hold a test request until the host cancels it.
	operation, err := first.Execute(ctx, "lithe/build/test", json.RawMessage(`{"root":".","scope":"workspace","operationID":"blocked"}`), 60_000)
	if err != nil {
		t.Fatalf("send the blocked request: %v", err)
	}
	saveProviderHeap(t, h, instance, 2048)
	second := requestProvider(t, h, p, instance)
	if second == first {
		t.Fatal("the request after the settings changed reused the old provider")
	}
	if first.Closed() {
		t.Fatal("the replaced provider closed while it still served a request")
	}
	if err := first.Cancel(ctx, operation); err != nil {
		t.Fatalf("cancel the blocked request: %v", err)
	}
	if _, err := operation.Wait(ctx); errors.Is(err, buildprovider.ErrClosed) {
		t.Fatal("closing the replaced provider failed the request it was serving")
	}
	awaitStateWithin(t, h, 30*time.Second, "the replaced provider's exit after its request", first.Closed)
}

func TestBuildProviderRestartsAfterSavingProjectToolchain(t *testing.T) {
	manifest := providerToolchainManifest(t)
	h := providerTestsHarnessWith(t, manifest)
	project := openProviderSettingsFixture(t, h, "block.marker")
	instance := settingsFixtureInstance(h, manifest)
	adapter := settingsToolchains{app: h.app}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	saveFixtureToolchain(t, ctx, h.app, newFixtureRuntime(t))
	first := requestProvider(t, h, project, instance)
	operation, err := first.Execute(ctx, "lithe/build/test", json.RawMessage(`{"root":".","scope":"workspace","operationID":"before-toolchain-save"}`), 60_000)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := adapter.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	changes := []toolchain.Edit{{
		Tool: restartFixtureTool,
		Pin:  &core.ToolchainPin{Home: newFixtureRuntime(t), Version: "3.12.4", Provider: "host:manual"},
	}}
	snapshot, err = adapter.Save(ctx, snapshot, changes)
	if err != nil {
		t.Fatal(err)
	}
	second := requestProvider(t, h, project, instance)
	if first == second {
		t.Fatal("saving a project toolchain pin reused the old build provider")
	}
	if first.Closed() {
		t.Fatal("saving a project toolchain pin stopped an active test")
	}
	if err := first.Cancel(ctx, operation); err != nil {
		t.Fatal(err)
	}
	if _, err := operation.Wait(ctx); errors.Is(err, buildprovider.ErrClosed) || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("replaced provider did not finish its test: %v", err)
	}
	awaitStateWithin(t, h, 30*time.Second, "the replaced provider's exit", first.Closed)
	if _, err := adapter.Save(ctx, snapshot, changes); err != nil {
		t.Fatal(err)
	}
	if again := requestProvider(t, h, project, instance); again != second {
		t.Fatal("saving the same pin replaced the build provider again")
	}
}

func TestPackagedBuildProviderKeepsWorkingWithUnreadableToolchainSources(t *testing.T) {
	for _, scope := range []string{"project", "global"} {
		t.Run(scope, func(t *testing.T) {
			manifest := providerSettingsManifest(t)
			h := providerTestsHarnessWith(t, manifest)
			project := openProviderSettingsFixture(t, h)
			instance := settingsFixtureInstance(h, manifest)
			first := requestProvider(t, h, project, instance)

			ctx, cancel := context.WithTimeout(project.ctx, 20*time.Second)
			defer cancel()
			var target string
			if scope == "project" {
				plan, err := h.app.kernel.ToolchainPinStorage(ctx)
				if err != nil {
					t.Fatal(err)
				}
				target = filepath.Join(project.root, filepath.FromSlash(plan.DocumentRelativePath))
			} else {
				catalog, err := h.app.kernel.ReadToolchainCatalogForWorkspace(ctx, nil, buildPlatform(), "")
				if err != nil {
					t.Fatal(err)
				}
				target = filepath.Join(h.app.globalToolchainRoot(), filepath.FromSlash(catalog.Storage.RelativePath))
			}
			if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
				t.Fatal(err)
			}
			if err := os.MkdirAll(target, 0o700); err != nil {
				t.Fatal(err)
			}
			if reused := requestProvider(t, h, project, instance); reused != first {
				t.Fatal("reusing a packaged provider depended on an unrelated toolchain file")
			}
			saveProviderHeap(t, h, instance, 2048)
			if restarted := requestProvider(t, h, project, instance); restarted == first {
				t.Fatal("plugin settings did not restart the packaged provider")
			}
		})
	}
}

// A native window started as a separate process cannot receive an in-memory
// settings notification. Both clients still read the same catalog.
func TestBuildProviderObservesGlobalToolchainSavedByAnotherClient(t *testing.T) {
	manifest := providerToolchainManifest(t)
	h := providerTestsHarnessWith(t, manifest)
	project := openProviderSettingsFixture(t, h)
	instance := settingsFixtureInstance(h, manifest)
	h.app.unsubscribeSettings()

	other := &App{kernel: h.app.kernel, store: h.store, plugins: h.app.plugins}
	adapter := settingsToolchains{app: other}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	save := func(home string) {
		t.Helper()
		snapshot, err := adapter.LoadScope(ctx, "global")
		if err != nil {
			t.Fatal(err)
		}
		for i := range snapshot.Tools {
			if snapshot.Tools[i].ID == restartFixtureTool {
				snapshot.Tools[i].CustomHomes = append(snapshot.Tools[i].CustomHomes, home)
			}
		}
		if _, err := adapter.Save(ctx, snapshot, []toolchain.Edit{{
			Tool: restartFixtureTool, Pin: &core.ToolchainPin{Home: home},
		}}); err != nil {
			t.Fatal(err)
		}
	}
	save(newFixtureRuntime(t))
	first := requestProvider(t, h, project, instance)
	save(newFixtureRuntime(t))
	if second := requestProvider(t, h, project, instance); second == first {
		t.Fatal("the next request reused a provider from before the global save")
	}
}

type toolchainStartupKernel struct {
	*testKernel
	starts  atomic.Int32
	entered chan struct{}
	release chan struct{}
	paths   chan string
}

func (k *toolchainStartupKernel) StartPluginBackend(ctx context.Context, start core.PluginBackendStart) (core.PluginBackendStarted, error) {
	if start.Role == "build" {
		select {
		case k.paths <- start.ExecutablePath:
		case <-ctx.Done():
			return core.PluginBackendStarted{}, ctx.Err()
		}
		if k.starts.Add(1) == 1 {
			close(k.entered)
			select {
			case <-k.release:
			case <-ctx.Done():
				return core.PluginBackendStarted{}, ctx.Err()
			}
		}
	}
	return k.Client.StartPluginBackend(ctx, start)
}

func TestBuildProviderRetriesAStartOvertakenByToolchainSave(t *testing.T) {
	kernel := &toolchainStartupKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		entered:    make(chan struct{}),
		release:    make(chan struct{}),
		paths:      make(chan string, 4),
	}
	manifest := providerToolchainManifest(t)
	h := providerTestsHarnessWith(t, manifest, kernel)
	project := openProviderSettingsFixture(t, h)
	instance := settingsFixtureInstance(h, manifest)
	ctx, cancel := context.WithTimeout(project.ctx, 40*time.Second)
	defer cancel()
	oldHome, newHome := newFixtureRuntime(t), newFixtureRuntime(t)
	saveFixtureToolchain(t, ctx, h.app, oldHome)
	result := make(chan error, 1)
	h.app.background(project, 0, func(context.Context) func(*App) {
		_, err := h.app.buildProvider(ctx, project, instance)
		result <- err
		return nil
	})
	select {
	case <-kernel.entered:
	case err := <-result:
		t.Fatalf("provider exited before reaching its startup gate: %v", err)
	case <-ctx.Done():
		t.Fatalf("provider did not reach its startup gate: %v", ctx.Err())
	}
	saveFixtureToolchain(t, ctx, h.app, newHome)
	close(kernel.release)
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("the original request failed after saving a toolchain: %v", err)
		}
	case <-ctx.Done():
		t.Fatalf("the original request did not finish: %v", ctx.Err())
	}
	if got := kernel.starts.Load(); got != 2 {
		t.Fatalf("provider starts = %d, want the superseded start followed by a retry", got)
	}
	for _, home := range []string{oldHome, newHome} {
		var path string
		select {
		case path = <-kernel.paths:
		default:
			t.Fatal("the startup did not report its executable")
		}
		want, err := filepath.EvalSymlinks(filepath.Join(home, filepath.FromSlash(fixtureRuntimePath())))
		if err != nil {
			t.Fatal(err)
		}
		if !sameProjectRoot(path, want) {
			t.Fatalf("provider executable = %q, want %q", path, want)
		}
	}
}

func saveFixtureToolchain(t *testing.T, ctx context.Context, app *App, home string) {
	t.Helper()
	adapter := settingsToolchains{app: app}
	snapshot, err := adapter.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := adapter.Save(ctx, snapshot, []toolchain.Edit{{
		Tool: restartFixtureTool,
		Pin:  &core.ToolchainPin{Home: home, Version: "3.12.4", Provider: "host:manual"},
	}}); err != nil {
		t.Fatal(err)
	}
}

type toolchainRetirementKernel struct {
	*uninstallOrderKernel
	failOn atomic.Pointer[string]
}

var errFixtureProviderStop = errors.New("injected provider stop failure")

func (k *toolchainRetirementKernel) StopPluginBackend(ctx context.Context, id string) error {
	err := k.Client.StopPluginBackend(ctx, id)
	if target := k.failOn.Load(); target != nil && id == *target && k.failOn.CompareAndSwap(target, nil) {
		return errors.Join(err, errFixtureProviderStop)
	}
	return err
}

func TestUninstallStopsToolchainRetireesBeforeRemovingPackage(t *testing.T) {
	kernel := &toolchainRetirementKernel{uninstallOrderKernel: &uninstallOrderKernel{
		testKernel: &testKernel{Client: core.NewClient()}, destroyed: make(chan bool, 4),
	}}
	manifest := providerToolchainManifest(t)
	h := providerTestsHarnessWith(t, manifest, kernel)
	project := openProviderSettingsFixture(t, h, "block.marker")
	instance := settingsFixtureInstance(h, manifest)
	kernel.directory = instance.PackageDirectory
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	saveFixtureToolchain(t, ctx, h.app, newFixtureRuntime(t))
	first := requestProvider(t, h, project, instance)
	if _, err := first.Execute(ctx, "lithe/build/test", json.RawMessage(`{"root":".","scope":"workspace","operationID":"before-uninstall"}`), 60_000); err != nil {
		t.Fatal(err)
	}
	saveFixtureToolchain(t, ctx, h.app, newFixtureRuntime(t))
	second := requestProvider(t, h, project, instance)
	if second == first || first.Closed() {
		t.Fatal("expected an active provider and its draining predecessor")
	}
	oldSession := first.Session().ID
	kernel.failOn.Store(&oldSession)
	server, stop := h.app.detachPluginPrograms(instance.PluginID)
	if err := h.app.plugins.Uninstall(ctx, instance.PluginID, server, stop); !errors.Is(err, errFixtureProviderStop) {
		t.Fatalf("uninstall with a failed stop = %v, want the retired provider's failure", err)
	}
	if _, err := os.Stat(instance.PackageDirectory); err != nil {
		t.Fatalf("uninstall removed the package while its retired provider's stop failed: %v", err)
	}
	server, stop = h.app.detachPluginPrograms(instance.PluginID)
	if err := h.app.plugins.Uninstall(ctx, instance.PluginID, server, stop); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		select {
		case packagePresent := <-kernel.destroyed:
			if !packagePresent {
				t.Fatal("a provider was destroyed after package removal")
			}
		default:
			t.Fatal("uninstall returned before both providers were destroyed")
		}
	}
}

// Closing the project closes a replaced provider at once with the others, without waiting for
// the request it still serves.
func TestClosingTheProjectClosesAReplacedProvider(t *testing.T) {
	manifest := providerSettingsManifest(t)
	h := providerTestsHarnessWith(t, manifest)
	p := openProviderSettingsFixture(t, h, "block.marker")
	instance := settingsFixtureInstance(h, manifest)

	first := requestProvider(t, h, p, instance)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := first.WaitReady(ctx); err != nil {
		t.Fatalf("the provider never became ready: %v", err)
	}
	if _, err := first.Execute(ctx, "lithe/build/test", json.RawMessage(`{"root":".","scope":"workspace","operationID":"blocked"}`), 60_000); err != nil {
		t.Fatalf("send the blocked request: %v", err)
	}
	saveProviderHeap(t, h, instance, 2048)
	second := requestProvider(t, h, p, instance)
	h.app.post(func(a *App) { a.stopBuildSessions(p, true) })
	awaitStateWithin(t, h, 30*time.Second, "both providers' exit", func() bool { return first.Closed() && second.Closed() })
}

// The window shows a provider's own message for a failed request, and Core's message when the
// provider sent none (#2143).
func TestLaunchFailureTextShowsTheProvidersOwnMessage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	failure := &buildprovider.ProviderError{Code: "serverError", Message: "Language server returned an error.", Detail: "Choose the installation in the plugin's settings."}
	if got := h.app.launchFailureText(fmt.Errorf("prepare: %w", failure)); got != failure.Detail {
		t.Fatalf("user text = %q, want the provider's message", got)
	}
	plain := &buildprovider.ProviderError{Code: "timeout", Message: "The request timed out."}
	if got := h.app.launchFailureText(plain); got != plain.Message {
		t.Fatalf("user text without a provider message = %q", got)
	}
}
