package workbench

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestPluginSettingsReloadInvalidatesOnlyOwningModelsAndKeepsRunningTask(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	running := h.app.beginBuildOperation(p, "build", "build", "", nil)
	p.build.selected, p.build.instances = 1, []buildInstance{
		{BuildInstance: core.BuildInstance{ID: "changed", ModelSource: "provider"}, PluginID: "changed.plugin", modelLoaded: true, modelLoading: true},
		{BuildInstance: core.BuildInstance{ID: "unrelated"}, PluginID: "other.plugin", modelLoaded: true},
	}
	h.app.reloadPluginBuildModels(p, "changed.plugin")
	if p.build.operation != running || p.build.operation.cancelled {
		t.Fatal("model reload stopped a running task")
	}
	if !p.build.instances[1].modelLoaded {
		t.Fatal("reload invalidated an unrelated plugin")
	}
	if p.build.instances[0].modelLoaded || !p.build.instances[0].modelReloadPending {
		t.Fatal("in-flight model did not retain the pending reload")
	}
	// The old read completes after publication. Its stale model must not become
	// loaded; the title bar lists the runs of every instance, so the unselected one
	// is read again instead of waiting for the Build window to select it.
	h.app.finishBuildModel(p, "changed", core.BuildModel{}, nil)
	if p.build.instances[0].modelLoaded || p.build.instances[0].modelReloadPending {
		t.Fatal("superseded model became current")
	}
	if !p.build.instances[0].modelLoading {
		t.Fatal("the invalidated model was not read again for the title bar")
	}
	if p.build.operation != running || !p.build.instances[1].modelLoaded {
		t.Fatal("completion disturbed the active task or unrelated model")
	}
}

func TestPluginSettingsLatestQueuedDeadlineRequiresRestart(t *testing.T) {
	h := newHarnessWithEmptyPluginService(t)
	h.open(t.TempDir())
	p := h.app.project
	// A past deadline is already terminal. No real-time waiting or native
	// session is needed to exercise the queued-publication timeout boundary.
	expired, cancel := context.WithDeadline(p.ctx, time.Unix(0, 0))
	defer cancel()
	p.ctx = expired
	server := &pluginServer{project: p, session: &pluginservice.LanguageSession{PluginID: "example", Version: "1.0.0"}, cancel: func() {}, done: make(chan struct{}), settingsGate: make(chan struct{}, 1)}
	server.settingsGate <- struct{}{}
	h.app.pluginServerMu.Lock()
	h.app.pluginServers = map[string]*pluginServer{"example": server}
	h.app.pluginServerMu.Unlock()
	defer func() { h.app.pluginServers = nil }()
	h.app.applyLivePluginSettings(p, "example", "1.0.0")
	h.settle()
	if _, pending := h.app.pluginSettingsRestart.Load("example"); !pending {
		t.Fatal("latest queued deadline silently discarded its saved configuration")
	}
}

func TestPluginSettingsRestartEffectMarksFailedServerRetryable(t *testing.T) {
	h := newHarnessWithEmptyPluginService(t)
	h.open(t.TempDir())
	p := h.app.project
	h.app.pluginServerMu.Lock()
	h.app.pluginServerFailed = map[string]*failedPluginServer{
		"fixture": {pluginID: "dev.lithe.test.lsp", languageID: "fixture", version: "1.0.0", project: p, message: "missing jdtls"},
	}
	h.app.pluginServerMu.Unlock()

	h.app.applyPluginSettingsEffects(core.PluginSettingsOwner{PluginID: "dev.lithe.test.lsp", Version: "1.0.0"}, []string{"restart"})
	runtime := h.app.pluginSettingsRuntime("dev.lithe.test.lsp")
	if !runtime.RestartRequired {
		t.Fatal("saving a restart-effect setting for a failed server did not set RestartRequired")
	}
	if runtime.Running {
		t.Fatal("failed server must still report Running=false")
	}
	if runtime.Version != "1.0.0" || runtime.Workspace != p.root {
		t.Fatalf("runtime = %+v, want version=1.0.0 workspace=%s", runtime, p.root)
	}
}
