package workbench

import (
	"context"
	"errors"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

func TestBackendArchitecture(t *testing.T) {
	got := backendArchitecture()
	if runtime.GOARCH == "amd64" {
		if got != "x64" {
			t.Fatalf("architecture = %q", got)
		}
		return
	}
	if got != runtime.GOARCH {
		t.Fatalf("architecture = %q, want %q", got, runtime.GOARCH)
	}
}

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
