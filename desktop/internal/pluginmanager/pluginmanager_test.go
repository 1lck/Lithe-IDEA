package pluginmanager

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

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
	return New(root, approvals, state), approvals, state, root
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
	if err := manager.Uninstall("example", "1.0.0"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the package survived: %v", err)
	}
	if _, found, err := approvals.Record("example", "1.0.0"); err != nil || found {
		t.Fatalf("the approval survived: found = %v, err = %v", found, err)
	}
}

func TestUninstallLastVersionForgetsEnablement(t *testing.T) {
	manager, _, state, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	if err := manager.Uninstall("example", "1.0.0"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	enabled, err := state.Enabled("example")
	if err != nil || enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
}

func TestUninstallKeepsEnablementWhileAnotherVersionRemains(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "example", "1.1.0")
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	if err := manager.Uninstall("example", "1.0.0"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	enabled, err := manager.Enabled("example")
	if err != nil || !enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
}

func TestUninstallRefusesMissingVersion(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := manager.Uninstall("example", "1.0.0"); !errors.Is(err, pluginpkg.ErrNotInstalled) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledRefusesUnknownPlugin(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := manager.SetEnabled("example", true); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledAndEnabledRoundTrip(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatalf("set enabled: %v", err)
	}
	enabled, err := manager.Enabled("example")
	if err != nil || !enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
	if err := manager.SetEnabled("example", false); err != nil {
		t.Fatalf("set disabled: %v", err)
	}
	enabled, err = manager.Enabled("example")
	if err != nil || enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
}
