package pluginmanager

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// newManager returns a manager over an empty plugin root.
func newManager(t *testing.T) (*Manager, *plugintrust.Store, *pluginstate.Store, string) {
	t.Helper()
	approvals := plugintrust.New(store.At(t.TempDir()))
	state := pluginstate.New(store.At(t.TempDir()))
	root := t.TempDir()
	return New(core.NewClient(), root, approvals, state), approvals, state, root
}

// uninstall removes plugin id; nothing of it runs in these tests.
func uninstall(manager *Manager, id string) error {
	_, err := manager.Apply(context.Background(), core.PluginUninstall, id, nil)
	return err
}

// enabled reports whether plugin id is installed and enabled.
func enabled(t *testing.T, manager *Manager, id string) bool {
	t.Helper()
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	for _, entry := range entries {
		if entry.Installed.ID == id {
			return entry.Enabled
		}
	}
	return false
}

// recorded reports whether the user's choice for plugin id is stored.
func recorded(t *testing.T, state *pluginstate.Store, id string) bool {
	t.Helper()
	entries, err := state.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, entry := range entries {
		if entry.PluginID == id {
			return true
		}
	}
	return false
}

// install puts one plugin version into the root.
func install(t *testing.T, root, id, version string) pluginpkg.Installed {
	t.Helper()
	staging, err := pluginpkg.NewStaging(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	installed, err := pluginpkg.Install(root, id, version, staging)
	if err != nil {
		t.Fatal(err)
	}
	return installed
}

// approve records an approval for one plugin version.
func approve(t *testing.T, approvals *plugintrust.Store, id, version string) {
	t.Helper()
	record := plugintrust.RecordFor(id, version, plugintrust.Request{Source: plugintrust.Marketplace})
	if err := approvals.Approve(record); err != nil {
		t.Fatal(err)
	}
}

func TestInstalledReportsVersionsAndEnablement(t *testing.T) {
	manager, _, state, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "example", "1.1.0")
	install(t, root, "other", "2.0.0")
	if err := state.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("entries = %+v", entries)
	}
	for _, entry := range entries {
		if entry.Installed.ID == "example" && !entry.Enabled {
			t.Fatalf("example is reported disabled: %+v", entry)
		}
		if entry.Installed.ID == "other" && entry.Enabled {
			t.Fatalf("other is reported enabled: %+v", entry)
		}
	}
}

func TestInstalledIsEmptyWithoutRoot(t *testing.T) {
	manager, _, _, _ := newManager(t)
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("entries = %+v", entries)
	}
}

func TestUninstallRemovesPackageAndApproval(t *testing.T) {
	manager, approvals, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	approve(t, approvals, "example", "1.0.0")
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the package survived: %v", err)
	}
	if _, found, err := approvals.Record("example", "1.0.0"); err != nil || found {
		t.Fatalf("the approval survived: found = %v, err = %v", found, err)
	}
}

func TestUninstallForgetsEnablement(t *testing.T) {
	manager, _, state, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if recorded(t, state, "example") {
		t.Fatal("the enablement choice survived the uninstall")
	}
}

func TestUninstallRemovesEveryVersion(t *testing.T) {
	manager, approvals, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "example", "1.1.0")
	approve(t, approvals, "example", "1.0.0")
	approve(t, approvals, "example", "1.1.0")
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	// Installing leaves the earlier version on disk, and the plugin page shows one
	// row per plugin, so removing only the newest would keep the plugin installed.
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a version survived: %v", err)
	}
	for _, version := range []string{"1.0.0", "1.1.0"} {
		if _, found, err := approvals.Record("example", version); err != nil || found {
			t.Fatalf("the approval of %s survived: found = %v, err = %v", version, found, err)
		}
	}
}

func TestUninstallRefusesAnUnknownPlugin(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := uninstall(manager, "example"); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledRefusesUnknownPlugin(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := manager.SetEnabled("example", true); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledAndInstalledRoundTrip(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if enabled(t, manager, "example") {
		t.Fatal("a plugin without a choice is enabled")
	}
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatalf("set enabled: %v", err)
	}
	if !enabled(t, manager, "example") {
		t.Fatal("the enabled plugin is reported disabled")
	}
	if err := manager.SetEnabled("example", false); err != nil {
		t.Fatalf("set disabled: %v", err)
	}
	if enabled(t, manager, "example") {
		t.Fatal("the disabled plugin is reported enabled")
	}
}

// Uninstalling removes what the plugin's programs wrote below the plugin root,
// so nothing of an uninstalled plugin stays on disk; the state of other plugins
// and the host's own files there are kept.
func TestUninstallRemovesThePluginState(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "other", "1.0.0")
	stateRoot := filepath.Join(root, pluginpkg.StateDirectory)
	for _, file := range []string{
		filepath.Join("example", "1.0.0", "jdk-sources", "String.java"),
		filepath.Join("example", "pages", "workspaces", "w", "page.json"),
		filepath.Join("other", "1.0.0", "cache"),
		"host-secret",
	} {
		path := filepath.Join(stateRoot, file)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the plugin's state survived: %v", err)
	}
	for _, kept := range []string{filepath.Join("other", "1.0.0", "cache"), "host-secret"} {
		if _, err := os.Stat(filepath.Join(stateRoot, kept)); err != nil {
			t.Fatalf("%s was removed with the plugin: %v", kept, err)
		}
	}
}

// Confirming an installation enables a plugin the user made no choice for, and
// keeps a choice the user made, such as disabling it before an update.
func TestEnableInstalledKeepsAnExplicitChoice(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "fresh", "1.0.0")
	install(t, root, "disabled", "1.0.0")
	if err := manager.SetEnabled("disabled", false); err != nil {
		t.Fatal(err)
	}
	install(t, root, "disabled", "1.1.0")
	for _, c := range []struct {
		id   string
		want bool
	}{{"fresh", true}, {"disabled", false}} {
		if _, err := manager.EnableInstalled(c.id); err != nil {
			t.Fatalf("enable %s: %v", c.id, err)
		}
		if got := enabled(t, manager, c.id); got != c.want {
			t.Fatalf("%s: enabled = %v, want %v", c.id, got, c.want)
		}
	}
	if _, err := manager.EnableInstalled("absent"); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("enabling a plugin that is not installed: %v", err)
	}
	// After an uninstall the choice is forgotten, so installing again enables it.
	if err := uninstall(manager, "disabled"); err != nil {
		t.Fatal(err)
	}
	install(t, root, "disabled", "1.1.0")
	if changed, err := manager.EnableInstalled("disabled"); err != nil || !changed {
		t.Fatalf("reinstall after uninstall: changed = %v, err = %v", changed, err)
	}
}
