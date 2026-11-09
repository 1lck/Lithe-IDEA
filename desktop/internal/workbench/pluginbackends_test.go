package workbench

import (
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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

func TestPluginDocumentURI(t *testing.T) {
	uri := pluginDocumentURI("/workspace", "/workspace/src/Main.java")
	if uri != "file:///src/Main.java" {
		t.Fatalf("uri = %q", uri)
	}
	// A document outside the workspace has no identity the server could match.
	if uri := pluginDocumentURI("/workspace", "/elsewhere/Main.java"); uri != "file:///../elsewhere/Main.java" {
		t.Fatalf("uri = %q", uri)
	}
	if uri := pluginDocumentURI("", "/workspace/src/Main.java"); uri != "" {
		t.Fatalf("uri = %q", uri)
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
