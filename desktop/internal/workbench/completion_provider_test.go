package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
)

const completionFixtureID = "dev.lithe.test.completion"

// completionProviderKernel supplies backend events without starting a process.
// The real host registers the provider, calls its function and decodes its reply.
type completionProviderKernel struct {
	*semanticTestKernel
	initialize     sync.Once
	ready          chan struct{}
	readyOnce      sync.Once
	requests       chan string
	replies        chan core.BackendEvent
	languageEvents chan core.BackendEvent
}

func (k *completionProviderKernel) StartPluginBackend(context.Context, core.PluginBackendStart) (core.PluginBackendStarted, error) {
	return core.PluginBackendStarted{SessionID: "completion-fixture"}, nil
}

func (k *completionProviderKernel) WaitBackendEvents(ctx context.Context, session string, _ int) ([]core.BackendEvent, error) {
	if session == "fake" {
		select {
		case event := <-k.languageEvents:
			return []core.BackendEvent{event}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	var initial []core.BackendEvent
	k.initialize.Do(func() {
		initial = []core.BackendEvent{
			{Type: "stateChanged", State: "ready"},
			{Type: "functionsChanged", Result: json.RawMessage(`{"functions":["fixture.complete"]}`)},
		}
	})
	if initial != nil {
		return initial, nil
	}
	k.readyOnce.Do(func() { close(k.ready) })
	select {
	case reply := <-k.replies:
		return []core.BackendEvent{reply}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (k *completionProviderKernel) InvokePluginFunctionInContext(ctx context.Context, _, operation, _, _ string, _, _ json.RawMessage, _ int) (string, error) {
	select {
	case k.requests <- operation:
		return operation, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (*completionProviderKernel) StopPluginBackend(context.Context, string) error    { return nil }
func (*completionProviderKernel) DestroyPluginBackend(context.Context, string) error { return nil }
func (*completionProviderKernel) CancelPluginOperation(context.Context, string, string) error {
	return nil
}

func (k *completionProviderKernel) reply(operation string) {
	k.replies <- core.BackendEvent{Type: "requestCompleted", OperationID: operation,
		Result: json.RawMessage(`{"value":[{"label":"fixtureCandidate"}]}`)}
}

func newCompletionProviderFixture(t *testing.T) (*semanticFixture, *completionProviderKernel) {
	t.Helper()
	root := t.TempDir()
	kernel := &completionProviderKernel{
		semanticTestKernel: &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}},
		ready:              make(chan struct{}),
		requests:           make(chan string, 2),
		replies:            make(chan core.BackendEvent, 2),
		languageEvents:     make(chan core.BackendEvent, 1),
	}
	directory := filepath.Join(root, completionFixtureID, "1.0.0")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := `{
		"schemaVersion":0,"id":"dev.lithe.test.completion","displayName":"Completion fixture",
		"version":"1.0.0","pluginAPIVersion":0,"requires":{"backend":0},
		"vendor":{"id":"dev.lithe.test","displayName":"Test","signatureRequirement":"publisherPackage"},
		"permissions":["backend.launch","editor.providers","documents.read"],
		"activationEvents":["onWorkspaceOpen"],
		"backend":{"launch":{"kind":"packaged","path":"fixture.exe"}}
	}`
	if err := os.WriteFile(filepath.Join(directory, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	// The fake kernel owns execution, but the package still passes native executable validation.
	copyTestBinary(t, filepath.Join(directory, "fixture.exe"))
	h := newHarness(t, kernel.semanticTestKernel)
	service, err := pluginservice.Open(kernel, h.store, root)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.AttachWorkbench(pluginWorkbench{app: h.app}); err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	f := openSemanticFixture(t, h, kernel.semanticTestKernel)
	if err := service.Manager.SetEnabled(completionFixtureID, true); err != nil {
		t.Fatal(err)
	}
	workspace := service.Contexts.Open(f.p.root)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	backend, err := service.Host.EnsureBackend(ctx, completionFixtureID)
	if err != nil {
		t.Fatal(err)
	}
	// The next event wait starts after the host has processed function registration.
	select {
	case <-kernel.ready:
	case <-ctx.Done():
		t.Fatal("completion fixture backend did not register its function")
	}
	caller := pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: completionFixtureID, SessionID: backend.Session.ID})
	registration, err := json.Marshal(struct {
		Context   pluginservice.ContextRef `json:"context"`
		ID        string                   `json:"id"`
		Selector  json.RawMessage          `json:"selector"`
		Providers json.RawMessage          `json:"providers"`
	}{workspace.ContextRef, "fixture", json.RawMessage(`{"fileNames":["A.java"]}`),
		json.RawMessage(`{"completion":{"function":"fixture.complete"}}`)})
	if err != nil {
		t.Fatal(err)
	}
	if _, failure := service.HostServices.Respond(caller, pluginhost.MethodPrefix+"editor/registerProviders", registration); failure != nil {
		t.Fatalf("registering the fixture provider: %+v", failure)
	}
	return f, kernel
}

func TestManualProviderCompletionDropsResultAfterCaretMove(t *testing.T) {
	f, kernel := newCompletionProviderFixture(t)
	delete(f.h.app.pluginServerLanguages, f.d.languageID)
	f.d.sync.reset()
	f.h.app.setDisableAutoCompletion(true)
	f.d.view.GoToNavigation(0, 3, false)
	f.h.settle()
	if err := f.h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	operation := awaitValueWithin(t, f.h, 3*time.Second, kernel.requests, "the completion provider request")
	if err := f.h.driver.Key(gfx.KeyLeft, 0); err != nil {
		t.Fatal(err)
	}
	kernel.reply(operation)
	f.h.settle()
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	f.h.settle()
	text, _ := f.d.view.Text()
	if strings.Contains(string(text), "fixtureCandidate") {
		t.Fatalf("Enter applied a completion from the old caret: %q", text)
	}
}

func TestManualCompletionWaitsForStartingLanguageServer(t *testing.T) {
	f, kernel := newCompletionProviderFixture(t)
	app, language := f.h.app, f.d.languageID
	preparation := beginCompletionLanguageDiscovery(f)
	if err := f.h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	// Register the synthetic session through the same path that resets document synchronization.
	session := f.server.session
	app.finishPluginServerPreparation(preparation, language, "", "", session, nil)
	f.server = app.pluginServers[session.PluginID]
	kernel.languageEvents <- core.BackendEvent{Type: "stateChanged", State: "ready"}
	awaitStateWithin(t, f.h, 3*time.Second, "the language server completion request", func() bool {
		return f.kernel.requestCount() == 1
	})
	operation := awaitValueWithin(t, f.h, 3*time.Second, kernel.requests, "the joined completion provider request")
	kernel.reply(operation)
	f.deliver(t, "op-1", pluginMethodCompletion, completionResult(t, core.PluginSemanticCompletionItem{Label: "serverCandidate"}))
	awaitStateWithin(t, f.h, 3*time.Second, "the merged completion popup", func() bool {
		return f.h.shows("serverCandidate") && f.h.shows("fixtureCandidate")
	})
}

func TestManualCompletionUsesProviderWhenDiscoveryFindsNoServer(t *testing.T) {
	f, kernel := newCompletionProviderFixture(t)
	app, language := f.h.app, f.d.languageID
	preparation := beginCompletionLanguageDiscovery(f)
	if err := f.h.driver.Key(gfx.KeySpace, gfx.ModifierControl); err != nil {
		t.Fatal(err)
	}
	app.finishPluginServerPreparation(preparation, language, "", "", nil, nil)
	operation := awaitValueWithin(t, f.h, 3*time.Second, kernel.requests, "the standalone completion provider request")
	kernel.reply(operation)
	f.h.settle()
	if !f.h.shows("fixtureCandidate") {
		t.Fatal("the provider candidate did not appear after discovery found no server")
	}
}

func beginCompletionLanguageDiscovery(f *semanticFixture) *pluginServerPreparation {
	app, language := f.h.app, f.d.languageID
	preparation := &pluginServerPreparation{project: f.p, cancel: func() {}}
	app.pluginServerMu.Lock()
	delete(app.pluginServerLanguages, language)
	delete(app.pluginServers, f.server.session.PluginID)
	app.pluginServerStarting = map[string]bool{language: true}
	app.pluginServerPreparations = map[string]*pluginServerPreparation{language: preparation}
	app.pluginServerMu.Unlock()
	f.d.sync.reset()
	return preparation
}
