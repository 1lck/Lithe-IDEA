package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

const restartFixtureID = "dev.lithe.test.provider-tests"

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
