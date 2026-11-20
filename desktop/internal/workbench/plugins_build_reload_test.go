package workbench

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const hotBuildPluginID = "io.github.example.hot-build"

const hotBuildPluginManifest = `{
  "schemaVersion": 0,
  "id": "io.github.example.hot-build",
  "displayName": "Hot Build Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0, "buildProviders": 0},
  "vendor": {"id": "io.github.example", "displayName": "Example", "signatureRequirement": "none"},
  "permissions": ["languageServer.launch", "process.build"],
  "activationEvents": ["onBuildSystem:hot-fixture"],
  "languages": [],
  "buildSystems": [{
    "id": "hot-fixture",
    "displayName": "Hot Fixture",
    "detection": {"markers": ["hotfixture.toml"]},
    "invocation": {"executables": [{"kind": "command", "command": "hot-fixture"}]},
    "provider": {
      "launch": {"kind": "packaged", "path": "bin/provider"},
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "model": {
      "source": "static",
      "file": "hotfixture.toml",
      "decoder": "toml",
      "map": {
        "projects": [{
          "each": "/package",
          "name": "/name",
          "targets": [{"each": "$/bin/*", "name": "/name", "tags": ["application"]}]
        }]
      }
    },
    "run": [{
      "id": "app",
      "source": "provider",
      "fromTargets": {"tags": ["application"]},
      "execution": "application"
    }]
  }]
}`

func writeHotBuildPluginArchive(t *testing.T, id, manifest string) string {
	t.Helper()
	archive := filepath.Join(t.TempDir(), id+".zip")
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, content := range map[string]string{
		id + "/plugin.json":  manifest,
		id + "/bin/provider": "#!/bin/sh\n",
	} {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := errors.Join(writer.Close(), file.Close()); err != nil {
		t.Fatal(err)
	}
	return archive
}

func setupHotBuildWorkspace(t *testing.T, dir, appName string) {
	t.Helper()
	content := "[package]\nname = \"" + appName + "\"\nversion = \"0.1.0\"\n\n[[bin]]\nname = \"" + appName + "\"\n"
	if err := os.WriteFile(filepath.Join(dir, "hotfixture.toml"), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

type blockedBuildDetectionKernel struct {
	*testKernel
	armed   atomic.Bool
	started chan struct{}
	release chan struct{}
}

func (k *blockedBuildDetectionKernel) DetectBuildSystemsWithOptions(ctx context.Context, root string, manifests []json.RawMessage, options core.BuildDetectOptions) (core.BuildDetection, error) {
	if k.armed.Load() {
		close(k.started)
		select {
		case <-ctx.Done():
			return core.BuildDetection{}, ctx.Err()
		case <-k.release:
			return core.BuildDetection{}, nil
		}
	}
	return k.Client.DetectBuildSystemsWithOptions(ctx, root, manifests, options)
}

func newBuildReloadStore(t *testing.T) *store.Store {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return store.At(dir)
}

func TestInvalidateBuildIncrementsGenerationAndDropsStaleDetection(t *testing.T) {
	kernel := &blockedBuildDetectionKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		started:    make(chan struct{}),
		release:    make(chan struct{}),
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       kernel,
		PluginKernel: kernel,
		PluginRoot:   t.TempDir(),
		Store:        newBuildReloadStore(t),
	})
	h.open(t.TempDir())
	p := h.app.project
	h.settle()

	kernel.armed.Store(true)
	var oldGen uint64
	h.app.post(func(a *App) {
		a.invalidateBuild(p)
		a.loadBuildSystems(p)
		oldGen = p.build.generation
	})
	awaitStateWithin(t, h, 8*time.Second, "in-flight detection to start", func() bool {
		select {
		case <-kernel.started:
			return true
		default:
			return false
		}
	})

	var invalidated bool
	var invalidatedGen uint64
	h.app.post(func(a *App) {
		a.invalidateBuild(p)
		invalidatedGen = p.build.generation
		invalidated = true
	})
	h.await("invalidateBuild to run", func() bool { return invalidated })
	if invalidatedGen <= oldGen {
		close(kernel.release)
		t.Fatalf("invalidateBuild did not increment generation: got %d, want > %d", invalidatedGen, oldGen)
	}
	if p.build.loading {
		close(kernel.release)
		t.Fatal("invalidateBuild kept p.build.loading true")
	}
	var staleChecked bool
	h.app.post(func(a *App) {
		a.finishBuildDetection(p, oldGen, []buildInstance{{BuildInstance: core.BuildInstance{ID: "stale"}}}, nil)
		staleChecked = true
	})
	h.await("stale finishBuildDetection check", func() bool { return staleChecked })
	if len(p.build.instances) != 0 {
		close(kernel.release)
		t.Fatalf("stale detection landed after invalidateBuild: %+v", p.build.instances)
	}
	close(kernel.release)
	h.settle()
	if len(p.build.instances) != 0 {
		t.Fatalf("blocked detection landed stale instances: %+v", p.build.instances)
	}
}

func TestPluginHotInstallEnableDisableUninstallReloadsBuildsAcrossTabs(t *testing.T) {
	client := &testKernel{Client: core.NewClient()}
	root := t.TempDir()
	alpha, beta := filepath.Join(root, "alpha"), filepath.Join(root, "beta")
	for _, dir := range []string{alpha, beta} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       client,
		PluginKernel: client,
		PluginRoot:   t.TempDir(),
		Store:        newBuildReloadStore(t),
	})
	h.app.settings.ProjectOpenDestination = settingswindow.ProjectOpenThisWindow
	t.Cleanup(func() { h.disposeTabs() })
	setupHotBuildWorkspace(t, alpha, "AlphaApp")
	setupHotBuildWorkspace(t, beta, "BetaApp")

	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	first := h.app
	var second *App
	for _, tab := range h.app.openTabs() {
		if tab != first {
			second = tab
		}
	}
	if second == nil || second.project == nil {
		t.Fatal("beta did not open in a second tab")
	}
	if first.project.titleConfiguration() != nil || second.project.titleConfiguration() != nil {
		t.Fatal("projects detected a run configuration before any build plugin was installed")
	}

	archive := writeHotBuildPluginArchive(t, hotBuildPluginID, hotBuildPluginManifest)
	done := make(chan bool, 1)
	var installErr error
	feedback := approvingPluginInstall(t)
	feedback.Failure = func(err error) { installErr = err }
	feedback.Finish = func(failed bool) { done <- failed }
	h.app.installPluginFromFile(archive, feedback)
	awaitStateWithin(t, h, 20*time.Second, "install completion", func() bool {
		select {
		case failed := <-done:
			if failed {
				t.Fatalf("hot plugin install failed: %v", installErr)
			}
			return true
		default:
			return false
		}
	})

	awaitBuilds := func(what string, check func() bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			h.settleTabs()
			if check() {
				return
			}
			// Drain driver wakes for any posted tab completions.
			select {
			case <-h.driver.Wakes():
				_ = h.driver.Pump()
			default:
			}
		}
		t.Fatalf("%s did not happen\nfirst: loaded=%v failed=%q instances=%+v runs=%+v\nsecond: loaded=%v failed=%q instances=%+v runs=%+v\nnotice=%q logFailed=%q",
			what,
			first.project.build.loaded, first.project.build.failed, first.project.build.instances, first.project.runConfigs.list,
			second.project.build.loaded, second.project.build.failed, second.project.build.instances, second.project.runConfigs.list,
			first.notice, lastNotice(h))
	}
	awaitBuilds("both tabs to detect build configs after hot install", func() bool {
		a := first.project.titleConfiguration()
		b := second.project.titleConfiguration()
		return a != nil && b != nil && a.Name != b.Name &&
			len(first.project.build.instances) == 1 && len(second.project.build.instances) == 1
	})

	// Disabling clears detected instances and title run configurations on every open tab.
	h.app.post(func(a *App) { a.setPluginEnabled(hotBuildPluginID, false) })
	awaitBuilds("both tabs to clear builds after disable", func() bool {
		return first.project.build.loaded && len(first.project.build.instances) == 0 && first.project.titleConfiguration() == nil &&
			second.project.build.loaded && len(second.project.build.instances) == 0 && second.project.titleConfiguration() == nil
	})

	// Enabling restores detected instances and title run configurations on every open tab.
	h.app.post(func(a *App) { a.setPluginEnabled(hotBuildPluginID, true) })
	awaitBuilds("both tabs to reload builds after enable", func() bool {
		a := first.project.titleConfiguration()
		b := second.project.titleConfiguration()
		return a != nil && b != nil && a.Name != b.Name &&
			len(first.project.build.instances) == 1 && len(second.project.build.instances) == 1
	})

	// Uninstalling removes detected instances and title run configurations on every open tab.
	h.app.post(func(a *App) { a.uninstallPlugin(hotBuildPluginID) })
	state := func() settingswindow.PluginState {
		states := h.app.pluginState.Load()
		if states == nil {
			return settingswindow.PluginState{}
		}
		return (*states)[hotBuildPluginID]
	}
	awaitBuilds("both tabs to clear builds after uninstall", func() bool {
		return !state().Installed &&
			first.project.build.loaded && len(first.project.build.instances) == 0 && first.project.titleConfiguration() == nil &&
			second.project.build.loaded && len(second.project.build.instances) == 0 && second.project.titleConfiguration() == nil
	})
}
