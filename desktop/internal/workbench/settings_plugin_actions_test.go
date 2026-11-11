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

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestSettingsActionConfirmsInvokesExistingProviderWithoutSaving(t *testing.T) {
	kernel := &settingsActionExecKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := providerTestsHarness(t, kernel)
	manifestPath := filepath.Join(h.app.plugins.Root, "dev.lithe.test.provider-tests", "1.0.0", "plugin.json")
	var manifest map[string]any
	if err := json.Unmarshal([]byte(providerTestsManifest), &manifest); err != nil {
		t.Fatal(err)
	}
	requires := manifest["requires"].(map[string]any)
	requires["settings"] = 0
	manifest["settingActions"] = []any{map[string]any{"id": "refresh", "title": "Refresh fixture", "function": "snapshot.refresh", "confirm": true}}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifestPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for _, name := range []string{"fixture.marker", "settings-action.marker"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("fixture"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// The host resolves the provider's build tool before it starts the provider; the fixture
	// provider never runs it.
	bin := t.TempDir()
	tool := filepath.Join(bin, "fixture-tool")
	if runtime.GOOS == "windows" {
		tool += ".exe"
		t.Setenv("PATHEXT", ".EXE")
	}
	if err := writeFakeExecutable(tool); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	p := openTestsPanel(t, h, root)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	editor, err := h.app.plugins.LoadSettingsEditor(ctx, "dev.lithe.test.provider-tests", root)
	if err != nil {
		t.Fatal(err)
	}
	// Display metadata is mutable view state and must never authorize a backend version.
	editor.Snapshot.State.Metadata.Version = "0.0.0"
	sources := pluginSettingsSources{app: h.app}
	beforeConfirmation := p.buildSessions.functionClients("dev.lithe.test.provider-tests")
	publication := h.app.toolchainRoot.Load()
	kernel.onPlan = func() { replacement := root; h.app.toolchainRoot.Store(&replacement) }
	if _, err := sources.Action(ctx, editor, "refresh", false); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("reopened project context was accepted: %v", err)
	}
	kernel.onPlan = nil
	h.app.toolchainRoot.Store(publication)
	// Confirmation must not start, attach or invoke a provider.
	confirmation, err := sources.Action(ctx, editor, "refresh", false)
	if err != nil || confirmation.Plan.Kind != "confirmationRequired" || confirmation.Completed {
		t.Fatalf("confirmation: %+v %v", confirmation, err)
	}
	if len(p.buildSessions.functionClients("dev.lithe.test.provider-tests")) != len(beforeConfirmation) {
		t.Fatal("confirmation started or attached a provider")
	}
	if _, err := os.Stat(filepath.Join(root, "action-invoked.marker")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unconfirmed action was invoked")
	}

	run := func(runCtx context.Context) (pluginservice.SettingsActionResult, error) {
		t.Helper()
		var result pluginservice.SettingsActionResult
		var actionErr error
		finished := false
		go func() {
			value, err := sources.Action(runCtx, editor, "refresh", true)
			h.app.post(func(*App) { result, actionErr, finished = value, err, true })
		}()
		awaitStateWithin(t, h, 8*time.Second, "settings action terminal", func() bool { return finished })
		return result, actionErr
	}
	before := p.buildSessions.functionClients("dev.lithe.test.provider-tests")
	if len(before) != 1 {
		t.Fatalf("warm provider count: %d", len(before))
	}
	completed, err := run(ctx)
	if err != nil || !completed.Completed {
		t.Fatalf("action result: %+v %v", completed, err)
	}
	after := p.buildSessions.functionClients("dev.lithe.test.provider-tests")
	if len(after) != 1 || after[0].Session().ID != before[0].Session().ID {
		t.Fatal("action replaced or duplicated its provider")
	}
	if _, err := os.Stat(filepath.Join(root, "action-invoked.marker")); err != nil {
		t.Fatal("provider function did not execute")
	}
	if err := os.WriteFile(filepath.Join(root, "block-action.marker"), []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}
	actionCtx, cancelAction := context.WithCancel(ctx)
	defer cancelAction()
	// The hook runs after Core registered the operation. Cancellation is posted
	// onto the window so the settings worker reaches its ordinary wait boundary.
	kernel.onInvoke = func() { h.app.post(func(*App) { cancelAction() }) }
	cancelled, cancelErr := run(actionCtx)
	if !errors.Is(cancelErr, context.Canceled) || cancelled.Completed {
		t.Fatalf("cancelled action: %+v %v", cancelled, cancelErr)
	}
	kernel.onInvoke = nil
	if err := before[0].Close(ctx); err != nil {
		t.Fatal(err)
	}
	unavailable, err := run(ctx)
	if !errors.Is(err, pluginbackend.ErrNoSession) || unavailable.Completed {
		t.Fatalf("missing provider: %+v %v", unavailable, err)
	}
	if !before[0].Closed() {
		t.Fatal("action restarted a closed provider")
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe", "plugin-settings.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("action saved project preferences: %v", err)
	}
}

type settingsActionExecKernel struct {
	*testKernel
	onInvoke func()
	onPlan   func()
}

func (k *settingsActionExecKernel) InvokePluginFunction(ctx context.Context, session, operation, plugin, function string, params json.RawMessage) (string, error) {
	id, err := k.Client.InvokePluginFunction(ctx, session, operation, plugin, function, params)
	if err == nil && k.onInvoke != nil {
		k.onInvoke()
	}
	return id, err
}

func (k *settingsActionExecKernel) PlanPluginSettingsAction(ctx context.Context, request core.PluginSettingsActionRequest) (core.PluginSettingsActionPlan, error) {
	plan, err := k.Client.PlanPluginSettingsAction(ctx, request)
	if err == nil && k.onPlan != nil {
		k.onPlan()
	}
	return plan, err
}
