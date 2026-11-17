package workbench

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

func TestPluginServerBuildReadinessIsRealAndAttachable(t *testing.T) {
	server := &pluginServer{}
	first := server.attachBuild(nil, pluginbackend.Session{ID: "shared"})
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := first.WaitReady(cancelled); !errors.Is(err, context.Canceled) {
		t.Fatalf("a new session reported ready before initialize: %v", err)
	}
	server.forwardBuild(core.BackendEvent{Type: "stateChanged", State: "ready"})
	if err := first.WaitReady(context.Background()); err != nil {
		t.Fatalf("the ready event did not reach the attached client: %v", err)
	}
	// A duplicated ready event must be harmless.
	server.forwardBuild(core.BackendEvent{Type: "stateChanged", State: "ready"})
	second := server.attachBuild(nil, pluginbackend.Session{ID: "shared"})
	if err := second.WaitReady(context.Background()); err != nil {
		t.Fatalf("an already-ready session was not attachable: %v", err)
	}
	_ = first.Close(context.Background())
	_ = second.Close(context.Background())
}

func TestPluginServerAttachAfterExitIsClosed(t *testing.T) {
	server := &pluginServer{}
	server.forwardBuild(core.BackendEvent{Type: "exit"})
	client := server.attachBuild(nil, pluginbackend.Session{ID: "shared"})
	if err := client.WaitReady(context.Background()); !errors.Is(err, buildprovider.ErrClosed) {
		t.Fatalf("attaching to an ended session returned %v, want ErrClosed", err)
	}

	readyThenExited := &pluginServer{}
	readyThenExited.forwardBuild(core.BackendEvent{Type: "stateChanged", State: "ready"})
	readyThenExited.forwardBuild(core.BackendEvent{Type: "exit"})
	client = readyThenExited.attachBuild(nil, pluginbackend.Session{ID: "shared"})
	if err := client.WaitReady(context.Background()); !errors.Is(err, buildprovider.ErrClosed) {
		t.Fatalf("attaching to a ready-then-exited session returned %v, want ErrClosed", err)
	}
}

func TestPluginServerLifecycleWithoutAStack(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	// A window without a plugin stack starts nothing and stops nothing; every entry
	// point must tolerate that rather than panic on a nil service.
	h.app.startPluginServer("java")
	if len(h.app.pluginServers) != 0 {
		t.Fatalf("servers = %v", h.app.pluginServers)
	}
	h.app.stopPluginServer("example")
	h.app.stopAllPluginServers()
	if h.app.pluginServers != nil {
		t.Fatalf("servers = %v", h.app.pluginServers)
	}
}

func TestStopPluginServerDropsTheLanguageMapping(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	// The bookkeeping is window-thread state, so it can be exercised without a real
	// server behind it.
	h.app.pluginServers = map[string]*pluginServer{"example": {cancel: func() {}}}
	h.app.pluginServerLanguages = map[string]string{"java": "example"}
	h.app.pluginServerStarting = map[string]bool{}
	h.app.stopPluginServer("example")
	if len(h.app.pluginServers) != 0 {
		t.Fatalf("servers = %v", h.app.pluginServers)
	}
	if len(h.app.pluginServerLanguages) != 0 {
		t.Fatalf("languages = %v", h.app.pluginServerLanguages)
	}
}

func TestStartPluginServerIgnoresAnEmptyLanguage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.startPluginServer("")
	if len(h.app.pluginServerStarting) != 0 {
		t.Fatalf("starting = %v", h.app.pluginServerStarting)
	}
}

func TestFinishPluginServerStartFailureNotifiesAndDeduplicates(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project

	h.app.finishPluginServerStart(p, "java", "dev.lithe.test.lsp", "1.0.0", nil, errors.New("missing runtime"))
	if len(h.app.notifications.list) != 1 {
		t.Fatalf("notifications = %d, want 1", len(h.app.notifications.list))
	}
	notice := h.app.notifications.list[0]
	if notice.kind != ui.ToastError || !strings.Contains(notice.text, "missing runtime") {
		t.Fatalf("notice = %+v", notice)
	}
	failed := h.app.pluginServerFailed["java"]
	if failed == nil || failed.pluginID != "dev.lithe.test.lsp" || failed.message != "missing runtime" || len(failed.logs) != 1 {
		t.Fatalf("failed = %+v", failed)
	}

	// Repeating the same failure in the same project must not spam another toast.
	h.app.finishPluginServerStart(p, "java", "dev.lithe.test.lsp", "1.0.0", nil, errors.New("missing runtime"))
	if len(h.app.notifications.list) != 1 || h.app.notifications.list[0].count != 1 {
		t.Fatalf("duplicate failure notified again: %+v", h.app.notifications.list)
	}

	// A different error message notifies again and updates the recorded failure.
	h.app.finishPluginServerStart(p, "java", "dev.lithe.test.lsp", "1.0.0", nil, errors.New("bad version"))
	if len(h.app.notifications.list) != 2 || h.app.pluginServerFailed["java"].message != "bad version" {
		t.Fatalf("updated failure state: notices=%d failed=%+v", len(h.app.notifications.list), h.app.pluginServerFailed["java"])
	}

	h.app.stopAllPluginServers()
	if len(h.app.pluginServerFailed) != 0 || len(h.app.pluginServerNotifiedErrors) != 0 {
		t.Fatalf("stopAllPluginServers left failure state: failed=%v notified=%v", h.app.pluginServerFailed, h.app.pluginServerNotifiedErrors)
	}
}

func TestPluginServerExitedWithErrorRetainsFailureAndLogs(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	server := &pluginServer{
		session:   &pluginservice.LanguageSession{PluginID: "dev.lithe.test.lsp", Version: "1.2.0", LanguageID: "java"},
		project:   p,
		cancel:    func() {},
		logs:      []lspLogLine{{level: "INFO", text: "[INFO] booting", tag: 6}},
		logsAdded: 1,
	}
	h.app.pluginServers = map[string]*pluginServer{"dev.lithe.test.lsp": server}
	h.app.pluginServerLanguages = map[string]string{"java": "dev.lithe.test.lsp"}

	h.app.pluginServerExited("dev.lithe.test.lsp", server, errors.New("exited early"))
	if len(h.app.pluginServers) != 0 || len(h.app.pluginServerLanguages) != 0 {
		t.Fatalf("exited server still registered: servers=%v langs=%v", h.app.pluginServers, h.app.pluginServerLanguages)
	}
	if h.app.pluginSettingsRuntime("dev.lithe.test.lsp").Running {
		t.Fatal("failed server still reported Running in plugin settings")
	}
	failed := h.app.pluginServerFailed["java"]
	if failed == nil || len(failed.logs) != 2 || !strings.Contains(failed.logs[1].text, "exited early") {
		t.Fatalf("failed = %+v", failed)
	}
	if len(h.app.notifications.list) != 1 || !strings.Contains(h.app.notifications.list[0].text, "exited early") {
		t.Fatalf("notifications = %+v", h.app.notifications.list)
	}
}

func TestRetryFailedLSPServerClearsFailureState(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	h.app.pluginServerFailed = map[string]*failedPluginServer{
		"java": {pluginID: "dev.lithe.test.lsp", languageID: "java", project: p, message: "missing runtime"},
	}
	h.app.pluginServerNotifiedErrors = map[string]string{"java": "missing runtime"}

	h.app.retryFailedLSPServer("java")
	if len(h.app.pluginServerFailed) != 0 || len(h.app.pluginServerNotifiedErrors) != 0 {
		t.Fatalf("retryFailedLSPServer did not clear failure state: failed=%v notified=%v", h.app.pluginServerFailed, h.app.pluginServerNotifiedErrors)
	}
}
