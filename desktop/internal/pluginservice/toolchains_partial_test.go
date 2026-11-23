package pluginservice

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// Real Core version selection must reject ambiguous/invalid installed facts
// without letting a bad version mask a healthy enabled plugin.
func TestToolchainPluginsKeepValidVersionsAndReportRejectedFacts(t *testing.T) {
	root := t.TempDir()
	entry := func(id, version string, valid bool) pluginmanager.Entry {
		t.Helper()
		dir := filepath.Join(root, id, version)
		if valid {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, pluginpkg.ManifestFile), []byte(`{"id":"`+id+`"}`), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		return pluginmanager.Entry{
			Installed: pluginpkg.Installed{ID: id, Version: version, Path: dir},
			Enabled:   true,
		}
	}
	healthy := entry("dev.lithe.test.healthy", "1.0.0", true)
	first := entry("dev.lithe.test.duplicate", "2.0.0", true)
	duplicate := first
	duplicate.Installed.Path = filepath.Join(root, "unreadable-duplicate")
	broken := entry("dev.lithe.test.invalid", "not-semver", false)

	for _, tc := range []struct {
		name, wantCode string
		entries        []pluginmanager.Entry
		wantIDs        []string
	}{
		{
			name:     "same version rejected without replacing the first",
			wantCode: "plugin.installed.duplicateVersion",
			entries:  []pluginmanager.Entry{first, duplicate, healthy},
			wantIDs:  []string{first.Installed.ID, healthy.Installed.ID},
		},
		{
			name:     "invalid version leaves healthy tools",
			wantCode: "plugin.installed.invalidVersion",
			entries:  []pluginmanager.Entry{broken, healthy},
			wantIDs:  []string{healthy.Installed.ID},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			service := &Service{kernel: core.NewClient()}
			plugins, err := service.ToolchainPlugins(context.Background(), tc.entries)
			if err == nil || !strings.Contains(err.Error(), tc.wantCode) {
				t.Fatalf("expected %s alongside usable plugins, got %v", tc.wantCode, err)
			}
			found := make(map[string]bool)
			for _, plugin := range plugins {
				found[plugin.PluginID] = true
				if plugin.PluginID == first.Installed.ID && plugin.Directory != first.Installed.Path {
					t.Fatalf("duplicate took precedence: %s", plugin.Directory)
				}
			}
			if len(found) != len(tc.wantIDs) {
				t.Fatalf("valid plugin count %d, want %d: %+v", len(found), len(tc.wantIDs), plugins)
			}
			for _, id := range tc.wantIDs {
				if !found[id] {
					t.Fatalf("valid plugin %q was lost after rejecting another version", id)
				}
			}
		})
	}
}
