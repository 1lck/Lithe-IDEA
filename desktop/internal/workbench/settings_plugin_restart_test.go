package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type restartBoundaryKernel struct {
	*testKernel
	started   chan context.Context
	release   chan struct{}
	destroyed chan struct{}
	planned   chan struct{}
}

func (k *restartBoundaryKernel) StopPluginBackend(ctx context.Context, _ string) error {
	k.started <- ctx
	select {
	case <-k.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (k *restartBoundaryKernel) DestroyPluginBackend(context.Context, string) error {
	close(k.destroyed)
	return nil
}
func (k *restartBoundaryKernel) PlanPluginLanguageServer(context.Context, json.RawMessage, string, core.PluginBackendDirectories) (core.PluginBackendPlan, error) {
	select {
	case <-k.destroyed:
	default:
		return core.PluginBackendPlan{}, errors.New("replacement planned before old native owner was destroyed")
	}
	k.planned <- struct{}{}
	return core.PluginBackendPlan{}, errors.New("test stopped at replacement planning; no process was started")
}

func TestPluginSettingsRestartWaitsForTeardownAndHonorsRevocation(t *testing.T) {
	for _, mode := range []string{"restart", "disable", "close-workspace"} {
		t.Run(mode, func(t *testing.T) {
			kernel := &restartBoundaryKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan context.Context, 1), release: make(chan struct{}), destroyed: make(chan struct{}), planned: make(chan struct{}, 1)}
			h := newHarness(t, kernel)
			h.open(t.TempDir())
			p := h.app.project
			preferences, plugins := t.TempDir(), t.TempDir()
			raw, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
			if err != nil {
				t.Fatal(err)
			}
			var fixture struct {
				Manifest json.RawMessage `json:"manifest"`
			}
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatal(err)
			}
			directory := filepath.Join(plugins, "dev.example.settings", "1.0.0")
			if err := os.MkdirAll(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), fixture.Manifest, 0o600); err != nil {
				t.Fatal(err)
			}
			service, err := pluginservice.Open(kernel, store.At(preferences), plugins)
			if err != nil {
				t.Fatal(err)
			}
			if err := service.Manager.SetEnabled("dev.example.settings", true); err != nil {
				t.Fatal(err)
			}
			h.app.plugins = service
			session := &pluginservice.LanguageSession{PluginID: "dev.example.settings", Version: "1.0.0", LanguageID: "fixture", Session: pluginbackend.Session{ID: "old-session"}}
			server := &pluginServer{session: session, project: p, cancel: func() {}, done: kernel.destroyed}
			h.app.pluginServers = map[string]*pluginServer{session.PluginID: server}
			h.app.pluginServerStarting = make(map[string]bool)
			h.app.pluginServerLanguages = map[string]string{"fixture": session.PluginID}
			var once sync.Once
			release := func() { once.Do(func() { close(kernel.release) }) }
			t.Cleanup(release)
			h.app.restartSettingsPlugin(session.PluginID, "1.0.0", "project", p.root)
			timer := time.NewTimer(5 * time.Second)
			defer timer.Stop()
			var cleanup context.Context
			select {
			case cleanup = <-kernel.started:
			case <-timer.C:
				t.Fatal("native teardown did not start")
			}
			if len(kernel.planned) != 0 {
				t.Fatal("replacement planned while teardown was blocked")
			}
			switch mode {
			case "disable":
				h.app.stopPluginServer(session.PluginID)
			case "close-workspace":
				p.cancel()
				h.app.stopAllPluginServers()
			}
			if cleanup.Err() != nil {
				t.Fatalf("workspace lifecycle cancelled native cleanup: %v", cleanup.Err())
			}
			release()
			h.settle()
			h.settle()
			if mode == "restart" {
				if len(kernel.planned) != 1 {
					t.Fatal("explicit restart did not plan a replacement after teardown")
				}
				if h.app.pluginServerSuppressed[session.PluginID] {
					t.Fatal("completed restart retained suppression")
				}
			} else {
				if len(kernel.planned) != 0 {
					t.Fatal("revoked restart planned a replacement")
				}
				if mode == "close-workspace" && h.app.pluginServerSuppressed[session.PluginID] {
					t.Fatal("workspace closure retained a restart-only suppression")
				}
			}
		})
	}
}
