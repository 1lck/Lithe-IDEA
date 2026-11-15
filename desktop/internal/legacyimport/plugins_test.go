package legacyimport

import (
	"os"
	"path/filepath"
	"testing"
)

func writePlugin(t *testing.T, root, id, record, version, manifest string) {
	t.Helper()
	directory := filepath.Join(root, id)
	if err := os.MkdirAll(filepath.Join(directory, version), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "installation.json"), []byte(record), 0o600); err != nil {
		t.Fatal(err)
	}
	if manifest != "" {
		if err := os.WriteFile(filepath.Join(directory, version, "plugin.json"), []byte(manifest), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// Installed marketplace and community packages are listed with their manifest's name;
// bundled, removed and mismatched records are not.
func TestMacPluginsListTheInstalledPackages(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "dev.example.java", `{"pluginID":"dev.example.java","activeVersion":"1.2.0","origin":"marketplace","status":"installed"}`,
		"1.2.0", `{"id":"dev.example.java","displayName":" Java "}`)
	writePlugin(t, root, "dev.example.db", `{"pluginID":{"rawValue":"dev.example.db"},"activeVersion":"0.3.1","origin":"community","status":"updateStaged"}`, "0.3.1", "")
	writePlugin(t, root, "dev.example.bundled", `{"pluginID":"dev.example.bundled","activeVersion":"1.0.0","origin":"bundled","status":"installed"}`, "1.0.0", "")
	writePlugin(t, root, "dev.example.gone", `{"pluginID":"dev.example.gone","activeVersion":"1.0.0","origin":"marketplace","status":"uninstallPending"}`, "1.0.0", "")
	writePlugin(t, root, "dev.example.other", `{"pluginID":"dev.example.elsewhere","activeVersion":"1.0.0","origin":"marketplace","status":"installed"}`, "1.0.0", "")
	writePlugin(t, root, "dev.example.escape", `{"pluginID":"dev.example.escape","activeVersion":"../..","origin":"marketplace","status":"installed"}`, "x", "")
	plugins := macPlugins(root)
	want := []Plugin{{ID: "dev.example.db", Name: "dev.example.db", Version: "0.3.1"}, {ID: "dev.example.escape", Name: "dev.example.escape", Version: "../.."}, {ID: "dev.example.java", Name: "Java", Version: "1.2.0"}}
	if len(plugins) != len(want) {
		t.Fatalf("plugins = %+v", plugins)
	}
	for i := range want {
		if plugins[i] != want[i] {
			t.Fatalf("plugins[%d] = %+v, want %+v", i, plugins[i], want[i])
		}
	}
	if macPlugins(filepath.Join(root, "missing")) != nil {
		t.Fatal("a missing root lists plugins")
	}
}

func TestWindowsPluginsListTheInstalledPackages(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "dev.example.java", `{"schemaVersion":1,"pluginId":"dev.example.java","version":"1.2.0","enabled":false}`,
		"1.2.0", `{"displayName":"Java"}`)
	writePlugin(t, root, "dev.example.bad", `not json`, "1.0.0", "")
	plugins := windowsPlugins(root)
	if len(plugins) != 1 || plugins[0] != (Plugin{ID: "dev.example.java", Name: "Java", Version: "1.2.0"}) {
		t.Fatalf("plugins = %+v", plugins)
	}
}
