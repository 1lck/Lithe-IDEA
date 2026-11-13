package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestDesktopStartupMakesInstalledPluginSettingsReachable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	preferences, plugins := t.TempDir(), t.TempDir()
	directory := filepath.Join(plugins, "dev.example.settings", "1.0.0")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(directory, pluginpkg.ManifestFile)
	if err := os.WriteFile(manifestPath, fixture.Manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	// As in the other headless harnesses, avoid querying AppKit's system
	// appearance without a native application loop. Plugin assembly is the
	// subject; the operating system's current theme is not a test dependency.
	if err := os.WriteFile(filepath.Join(preferences, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), store.At(preferences), "test")
	options.PluginRoot = plugins
	options.Languages = []string{"en"}
	// This integration isolates plugin startup. AI provider discovery has its own
	// test with written configuration files and is not triggered here.
	options.AIKernel = nil
	h := newHarnessWithOptions(t, options)
	if h.app.plugins == nil {
		t.Fatal("production startup omitted the plugin Core consumer")
	}
	h.open(t.TempDir())
	h.app.openSettingsPage("startup-test", settingsHome)
	h.settle()
	states := h.app.pluginState.Load()
	if states == nil || !(*states)["dev.example.settings"].Installed {
		t.Fatal("opening general settings did not publish the installed plugin state")
	}

	source := pluginSettingsSources{app: h.app}
	editor, err := source.Load(ctx, "dev.example.settings")
	if err != nil {
		t.Fatal(err)
	}
	if len(editor.Snapshot.State.Rows) != 7 || editor.Snapshot.Workspace() != h.app.project.root {
		t.Fatalf("startup did not expose real installed settings: %+v", editor.Snapshot.State)
	}
	result, err := source.Save(ctx, editor, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("false")}})
	if err != nil || !result.Committed || result.Readback == nil {
		t.Fatalf("startup settings save failed: %+v %v", result, err)
	}
	if string(result.Readback.State.Settings["flag"]) != "false" {
		t.Fatal("production consumer did not read back its native source")
	}
	actual, err := os.ReadFile(manifestPath)
	if err != nil || string(actual) != string(fixture.Manifest) {
		t.Fatalf("startup changed the installed package: %v", err)
	}
}
