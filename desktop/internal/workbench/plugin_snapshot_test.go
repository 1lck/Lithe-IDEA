package workbench

import (
	"context"
	"encoding/json"
	"slices"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type pluginSnapshotKernel struct {
	*testKernel
	selections atomic.Int32
	visibility atomic.Int32
	hidden     atomic.Bool
}

func (k *pluginSnapshotKernel) SelectInstalledPluginVersions(ctx context.Context, entries []core.InstalledPluginFact, includeDisabled bool) (core.InstalledPluginSelection, error) {
	k.selections.Add(1)
	return k.Client.SelectInstalledPluginVersions(ctx, entries, includeDisabled)
}

func (k *pluginSnapshotKernel) ConfigureVisibility(ctx context.Context, manifests []json.RawMessage) (core.VisibilityConfiguration, error) {
	k.visibility.Add(1)
	configuration, err := k.Client.ConfigureVisibility(ctx, manifests)
	k.hidden.Store(slices.Contains(configuration.HiddenDirectoryNames, "snapshot-out"))
	return configuration, err
}

// A reload owns one selection/read snapshot. A later reload must select again,
// so disabling a plugin immediately withdraws every contribution.
func TestPluginReloadSelectsInstalledVersionsOnce(t *testing.T) {
	preferences := store.At(t.TempDir())
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
