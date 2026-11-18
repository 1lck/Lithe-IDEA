package workbench

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

func TestPluginWorkspaceRequestKeepsIdentityAcrossReopen(t *testing.T) {
	kernel := &testKernel{Client: core.NewClient()}
	h := newHarness(t, kernel)
	service, err := pluginservice.Open(kernel, h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	root := t.TempDir()
	h.open(root)
	first := h.app.pluginBackendRequest()
	if first.Context.ContextID == "" {
		t.Fatal("the project opened before owning its plugin workspace context")
	}
	h.app.closeProject()
	h.settle()
	if h.app.project != nil {
		t.Fatal("the first project did not close")
	}
	h.open(root)
	second := h.app.pluginBackendRequest()
	if first.WorkingDirectory != second.WorkingDirectory || first.Context == second.Context {
		t.Fatal("reopening a path reused the previous language-server request identity")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.app.plugins.ActivateWorkspace(ctx, nil, first.Context); !errors.Is(err, pluginservice.ErrContextExpired) {
		t.Fatalf("the old queued activation adopted the reopened project: %v", err)
	}
	if _, err := h.app.plugins.Contexts.Lookup(second.Context); err != nil {
		t.Fatalf("a late activation invalidated the new project: %v", err)
	}
}

func TestClosingProjectCancelsRuntimePreparationAndIgnoresLateResult(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	previous := &pluginServerPreparation{project: h.app.project, cancel: cancel}
	h.app.pluginServerPreparations = map[string]*pluginServerPreparation{"fixture": previous}
	h.app.pluginServerStarting = map[string]bool{"fixture": true}
	h.app.stopAllPluginServers()
	if ctx.Err() != context.Canceled || len(h.app.pluginServerPreparations) != 0 {
		t.Fatal("project close left runtime preparation running")
	}
	next := &pluginServerPreparation{project: h.app.project, cancel: func() {}}
	h.app.pluginServerPreparations = map[string]*pluginServerPreparation{"fixture": next}
	h.app.pluginServerStarting = map[string]bool{"fixture": true}
	h.app.finishPluginServerPreparation(previous, "fixture", "dev.example.runtime", "1", nil, context.Canceled)
	if h.app.pluginServerPreparations["fixture"] != next || !h.app.pluginServerStarting["fixture"] {
		t.Fatal("late result cleared the next project's preparation")
	}
}

func TestDisableInvalidatesPreparationEvenAfterReenable(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	previous := &pluginServerPreparation{project: h.app.project, cancel: cancel, pluginID: "dev.example.runtime"}
	h.app.pluginServerPreparations = map[string]*pluginServerPreparation{"fixture": previous}
	h.app.pluginServerStarting = map[string]bool{"fixture": true}
	h.app.detachPluginServer(previous.pluginID)
	if ctx.Err() != context.Canceled || h.app.pluginServerStarting["fixture"] {
		t.Fatal("disabling did not cancel and invalidate the old preparation")
	}
	delete(h.app.pluginServerSuppressed, previous.pluginID)
	h.app.finishPluginServerPreparation(previous, "fixture", previous.pluginID, "1", nil, context.Canceled)
	if len(h.app.pluginServerFailed) != 0 || len(h.app.notifications.list) != 0 {
		t.Fatal("late canceled start affected the reenabled plugin")
	}
}

func TestRuntimePreparationStatusShowsProgressAndCancels(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	attempt := &pluginServerPreparation{project: f.p, cancel: cancel}
	progress := pluginruntime.Progress{ID: "engine", Phase: "downloading", Received: 48 << 20, Total: 192 << 20}
	attempt.progress.Store(&progress)
	a.pluginServers = nil
	a.pluginServerLanguages = nil
	a.pluginServerPreparations = map[string]*pluginServerPreparation{f.d.languageID: attempt}
	a.invalidator.Invalidate()
	f.h.settle()
	if a.lspStatusText() != i18n.Shared(a.language(), "desktop.status.lspStarting") || a.lspStatusColor() != a.colors.Warning {
		t.Fatal("runtime preparation is invisible in the status bar")
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if !f.h.shows(settingswindow.RuntimeProgressText(a.language(), progress)) {
		t.Fatal("server menu does not show runtime download progress")
	}
	f.h.clickNamed(f.d.languageID)
	f.h.settle()
	f.h.clickNamed(i18n.Shared(a.language(), "desktop.marketplace.cancel"))
	f.h.settle()
	if ctx.Err() != context.Canceled {
		t.Fatal("cancel action left the runtime download running")
	}
}

func TestRuntimePreparationCancelWinsQueuedSuccessfulResult(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	attempt := &pluginServerPreparation{project: h.app.project, cancel: func() {}}
	h.app.pluginServerPreparations = map[string]*pluginServerPreparation{"fixture": attempt}
	h.app.pluginServerStarting = map[string]bool{"fixture": true}
	attempt.stop()
	h.app.finishPluginServerPreparation(attempt, "fixture", "dev.example.runtime", "1", nil, nil)
	if h.app.pluginServerFailed["fixture"] == nil || h.app.pluginServerStarting["fixture"] || len(h.app.notifications.list) != 0 {
		t.Fatal("queued completion ignored cancellation or produced an error toast")
	}
}
