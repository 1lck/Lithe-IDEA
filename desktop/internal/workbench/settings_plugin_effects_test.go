package workbench

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestPluginSettingsReloadInvalidatesOnlyOwningModelsAndKeepsRunningTask(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	running := &buildOperation{}
	p.build = buildState{selected: 1, operation: running, instances: []buildInstance{
		{BuildInstance: core.BuildInstance{ID: "changed"}, PluginID: "changed.plugin", modelLoaded: true, modelLoading: true},
		{BuildInstance: core.BuildInstance{ID: "unrelated"}, PluginID: "other.plugin", modelLoaded: true},
	}}
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
	// loaded, and an unselected instance must not eagerly start another process.
	h.app.finishBuildModel(p, "changed", core.BuildModel{}, nil)
	if p.build.instances[0].modelLoaded || p.build.instances[0].modelLoading || p.build.instances[0].modelReloadPending {
		t.Fatal("superseded model became current")
	}
	if p.build.operation != running || !p.build.instances[1].modelLoaded {
		t.Fatal("completion disturbed the active task or unrelated model")
	}
}

func TestPluginSettingsLatestQueuedDeadlineRequiresRestart(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	// A past deadline is already terminal. No real-time waiting or native
	// session is needed to exercise the queued-publication timeout boundary.
	expired, cancel := context.WithDeadline(p.ctx, time.Unix(0, 0))
	defer cancel()
	p.ctx = expired
	server := &pluginServer{project: p, session: &pluginservice.LanguageSession{PluginID: "example", Version: "1.0.0"}, cancel: func() {}, done: make(chan struct{}), settingsGate: make(chan struct{}, 1)}
	server.settingsGate <- struct{}{}
	h.app.pluginServers = map[string]*pluginServer{"example": server}
	h.app.plugins = &pluginservice.Service{}
	h.app.applyLivePluginSettings(p, "example", "1.0.0")
	h.settle()
	if _, pending := h.app.pluginSettingsRestart.Load("example"); !pending {
		t.Fatal("latest queued deadline silently discarded its saved configuration")
	}
}
