package pluginservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// lifecycleService opens a service over a plugin root holding version 1.0.0
// of plugin example, and returns it with the root.
func lifecycleService(t *testing.T) (*Service, string) {
	t.Helper()
	root := t.TempDir()
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), root)
	if err != nil {
		t.Fatal(err)
	}
	pkg := filepath.Join(root, "example", "1.0.0")
	if err := os.MkdirAll(pkg, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pkg, pluginpkg.ManifestFile), []byte(`{"id":"example","version":"1.0.0"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return service, root
}

// runningBackend registers a backend session for id whose stop reports what
// it saw on disk when it was asked to end.
func runningBackend(service *Service, id string, stopped func()) *BackendSession {
	done := make(chan struct{})
	session := &BackendSession{
		host: service.Host, PluginID: id, Session: pluginbackend.Session{ID: "session-" + id},
		functions: map[string]bool{}, waiters: map[string]chan core.BackendEvent{},
		done: done, changed: make(chan struct{}), ready: true,
		cancel: func() { stopped(); close(done) },
	}
	service.Host.mu.Lock()
	service.Host.sessions[id] = session
	service.Host.mu.Unlock()
	return session
}

// Uninstalling a plugin stops its backend before its package and state go, so
// the backend cannot write the state again; another plugin's backend runs on.
func TestUninstallStopsTheBackendBeforeRemovingThePlugin(t *testing.T) {
	service, root := lifecycleService(t)
	state := filepath.Join(root, pluginStateDirectory, "example", "1.0.0", "cache")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	stoppedWithPackage := false
	runningBackend(service, "example", func() {
		_, err := os.Stat(filepath.Join(root, "example"))
		stoppedWithPackage = err == nil
	})
	runningBackend(service, "other", func() { t.Error("the other plugin's backend was stopped") })

	if err := service.Uninstall(context.Background(), "example", nil); err != nil {
		t.Fatal(err)
	}
	if !stoppedWithPackage {
		t.Fatal("the backend was not stopped before the package was removed")
	}
	if service.Host.Running("example") != nil {
		t.Fatal("the uninstalled plugin's backend is still registered")
	}
	if service.Host.Running("other") == nil {
		t.Fatal("the other plugin's backend stopped")
	}
	if _, err := os.Stat(filepath.Join(root, pluginStateDirectory, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the state survived: %v", err)
	}
}

// Disabling a plugin records the choice and stops its backend.
func TestDisableStopsTheBackend(t *testing.T) {
	service, _ := lifecycleService(t)
	if err := service.Manager.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	stopped, enabledWhenStopped := false, true
	runningBackend(service, "example", func() {
		stopped = true
		enabled, err := service.Manager.Enabled("example")
		if err != nil {
			t.Error(err)
		}
		enabledWhenStopped = enabled
	})
	if err := service.Disable(context.Background(), "example", nil); err != nil {
		t.Fatal(err)
	}
	if !stopped {
		t.Fatal("the disabled plugin's backend was not stopped")
	}
	if enabledWhenStopped {
		t.Fatal("the backend stopped before the plugin was recorded as disabled")
	}
	if service.Host.Running("example") != nil {
		t.Fatal("the disabled plugin's backend is still registered")
	}
	if err := service.Disable(context.Background(), "absent", nil); !errors.Is(err, pluginmanager.ErrUnknownPlugin) {
		t.Fatalf("disable a plugin that is not installed = %v", err)
	}
}
