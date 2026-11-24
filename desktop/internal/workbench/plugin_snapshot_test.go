package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type pluginSnapshotKernel struct {
	*testKernel
	selections atomic.Int32
	visibility atomic.Int32
	hidden     atomic.Bool
	blockFirst bool
	entered    chan struct{}
	release    chan struct{}
	enterOnce  sync.Once
}

func (k *pluginSnapshotKernel) SelectInstalledPluginVersions(ctx context.Context, entries []core.InstalledPluginFact, includeDisabled bool) (core.InstalledPluginSelection, error) {
	if call := k.selections.Add(1); call == 1 && k.blockFirst {
		k.enterOnce.Do(func() { close(k.entered) })
		deadline := time.NewTimer(8 * time.Second)
		defer deadline.Stop()
		select {
		case <-k.release:
		case <-ctx.Done():
			return core.InstalledPluginSelection{}, ctx.Err()
		case <-deadline.C:
		}
	}
	return k.Client.SelectInstalledPluginVersions(ctx, entries, includeDisabled)
}

func (k *pluginSnapshotKernel) ConfigureVisibility(ctx context.Context, manifests []json.RawMessage) (core.VisibilityConfiguration, error) {
	k.visibility.Add(1)
	configuration, err := k.Client.ConfigureVisibility(ctx, manifests)
	k.hidden.Store(slices.Contains(configuration.HiddenDirectoryNames, "snapshot-out"))
	return configuration, err
}

func newPluginSnapshotStore(t *testing.T) *store.Store {
	t.Helper()
	dir := t.TempDir()
	// An explicit theme keeps New from asking macOS for its appearance without a running app.
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return store.At(dir)
}

// A reload owns one selection/read snapshot. A later reload must select again,
// so disabling a plugin immediately withdraws every contribution.
func TestPluginReloadSelectsInstalledVersionsOnce(t *testing.T) {
	preferences := newPluginSnapshotStore(t)
	root := t.TempDir()
	const id = "dev.lithe.test.reload-snapshot"
	installHiddenFoldersPlugin(t, preferences, root, id, hiddenFoldersManifest(t, id, "fixture-snapshot", "snapshot-out"))
	kernel := &pluginSnapshotKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, PluginRoot: root, Store: preferences, Languages: []string{"en-US"}})
	clearHiddenFolders(t)
	h.settle()
	for _, enabled := range []bool{true, false, true} {
		if err := pluginstate.New(preferences).SetEnabled(id, enabled); err != nil {
			t.Fatal(err)
		}
		beforeSelections, beforeVisibility := kernel.selections.Load(), kernel.visibility.Load()
		h.app.reloadPluginLanguages()
		h.settle()
		if got := kernel.visibility.Load() - beforeVisibility; got != 1 {
			t.Fatalf("enabled=%v: visibility calls = %d, want 1", enabled, got)
		}
		if got := kernel.hidden.Load(); got != enabled {
			t.Fatalf("enabled=%v: plugin hidden directory active = %v", enabled, got)
		}
		if got := kernel.selections.Load() - beforeSelections; got != 1 {
			t.Fatalf("enabled=%v: installed version selections = %d, want 1 shared by all reload consumers", enabled, got)
		}
	}
}

// A superseded reload must not overwrite newer languages, hidden directories, or
// UI contributions when it finishes out of order, while still unblocking initial loads.
func TestPluginReloadDropsStaleCompletion(t *testing.T) {
	preferences := newPluginSnapshotStore(t)
	root := t.TempDir()
	const id = "dev.lithe.test.reload-stale"
	manifest := []byte(`{
  "schemaVersion": 0,
  "id": "dev.lithe.test.reload-stale",
  "displayName": "Stale Reload Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0, "languages": 0, "ui": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build", "ui.contribute"],
  "activationEvents": ["onBuildSystem:fixture-snapshot", "onView:dev.lithe.test.reload-stale.window", "onCommand:dev.lithe.test.reload-stale.command"],
  "languages": [{"id": "snapshot-lang", "displayName": "Snapshot Lang", "fileExtensions": ["snapshot"]}],
  "buildSystems": [{
    "id": "fixture-snapshot",
    "displayName": "Fixture Build",
    "detection": {"markers": ["fixture.build"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "tasks": [{"id": "build", "displayName": "Build", "group": "build", "scopes": ["project"], "arguments": ["build"]}],
    "layout": {"hiddenDirectoryNames": ["snapshot-out"]}
  }],
  "ui": {
    "toolWindows": [{"id": "dev.lithe.test.reload-stale.window", "title": "Snapshot", "placement": "right", "text": "Snapshot"}],
    "commands": [{"id": "dev.lithe.test.reload-stale.command", "title": "Snapshot Command", "toolWindowID": "dev.lithe.test.reload-stale.window", "placements": ["commandPalette"]}]
  }
}`)
	if _, err := pluginhost.Validate(t.Context(), core.NewClient(), manifest, pluginhost.Declared()); err != nil {
		t.Fatal(err)
	}
	installHiddenFoldersPlugin(t, preferences, root, id, manifest)
	if err := pluginstate.New(preferences).SetEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	kernel := &pluginSnapshotKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		blockFirst: true,
		entered:    make(chan struct{}),
		release:    make(chan struct{}),
	}
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(kernel.release) }) }
	t.Cleanup(release)

	h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, PluginRoot: root, Store: preferences, Languages: []string{"en-US"}})
	clearHiddenFolders(t)
	h.settle()

	h.app.reloadPluginLanguages()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	select {
	case <-kernel.entered:
	case <-deadline.C:
		t.Fatal("first reload did not reach version selection before deadline")
	}

	if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
		t.Fatal(err)
	}
	h.app.reloadPluginLanguages()
	const windowItemID = pluginItemPrefix + "dev.lithe.test.reload-stale.window"
	awaitStateWithin(t, h, 8*time.Second, "newer reload to apply contributions", func() bool {
		initial := h.app.initialLanguageLoad.Load()
		_, hasWindow := h.app.chrome.index[windowItemID]
		return kernel.visibility.Load() == 1 && kernel.hidden.Load() && initial != nil && initial.closed.Load() && hasWindow
	})

	release()
	h.settle()
	if got := kernel.visibility.Load(); got != 1 {
		t.Fatalf("visibility calls = %d, want 1 (stale reload must be dropped)", got)
	}
	if !kernel.hidden.Load() {
		t.Fatal("stale reload cleared Core hidden directory")
	}
	if _, ok := h.app.chrome.index[windowItemID]; !ok {
		t.Fatal("stale reload removed plugin tool window")
	}
	if len(h.app.pluginCommands) != 1 || h.app.pluginCommands[0].ID != "dev.lithe.test.reload-stale.command" {
		t.Fatalf("pluginCommands = %+v, want newer reload command", h.app.pluginCommands)
	}
	if lang, ok := h.app.syntaxRegistry().ForPath("sample.snapshot"); !ok || lang.ID != "snapshot-lang" {
		t.Fatalf("language = %+v, ok = %v, want snapshot-lang", lang, ok)
	}
	if fileicons.SetHiddenDirectoryNames([]string{"snapshot-out"}) {
		t.Fatal("stale reload cleared hidden directory icons")
	}
}
