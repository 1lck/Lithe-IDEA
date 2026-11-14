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
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	editor, err := source.Load(ctx, "dev.example.settings", i18n.English)
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

// A package translation that cannot be read, and one Core refuses, each leave one warning while
// the page still loads in manifest text; a language without a translation file logs nothing.
func TestPluginSettingsLoadLogsSkippedAndRefusedTranslations(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	preferences, plugins := t.TempDir(), t.TempDir()
	directory := filepath.Join(plugins, "dev.lithe.fixture.settings", "0.1.0")
	// l10n/zh-Hans.json is a directory, so the adapter cannot read it; l10n/zh.json is not JSON.
	if err := os.MkdirAll(filepath.Join(directory, "l10n", "zh-Hans.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{pluginpkg.ManifestFile: manifest, "l10n/zh.json": []byte("settings: {}")} {
		if err := os.WriteFile(filepath.Join(directory, filepath.FromSlash(name)), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(preferences, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), store.At(preferences), "test")
	options.PluginRoot = plugins
	options.Languages = []string{"en"}
	options.AIKernel = nil
	h := newHarnessWithOptions(t, options)
	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	warnings := func() []string {
		log.mu.Lock()
		defer log.mu.Unlock()
		var reasons []string
		for _, event := range log.events {
			if event.Fields["operation"] == "plugin_settings_load" {
				if event.Level != core.LevelWarn || event.Event != pluginSettingsLoadRejectedEvent {
					t.Fatalf("plugin settings load logged %s %s %v", event.Level, event.Event, event.Fields)
				}
				reasons = append(reasons, event.Fields["reason"].(string))
			}
		}
		return reasons
	}
	source := pluginSettingsSources{app: h.app}
	editor, err := source.Load(ctx, "dev.lithe.fixture.settings", i18n.Chinese)
	if err != nil {
		t.Fatal(err)
	}
	if editor.Snapshot.State.Localization == nil || editor.Snapshot.State.Localization.Applied != nil {
		t.Fatalf("a translation was applied: %+v", editor.Snapshot.State.Localization)
	}
	if got := warnings(); len(got) != 2 || got[0] != "localization_unreadable" || got[1] != "invalid_localization" {
		t.Fatalf("warnings %v", got)
	}
	if _, err := source.Load(ctx, "dev.lithe.fixture.settings", i18n.English); err != nil {
		t.Fatal(err)
	}
	if got := warnings(); len(got) != 2 {
		t.Fatalf("a load without a translation file logged %v", got)
	}
}
