package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

type settingsFormSource struct {
	store     *pluginsettings.Store
	manifest  json.RawMessage
	workspace string
}

func (s settingsFormSource) Load(ctx context.Context, _ string) (pluginservice.SettingsEditor, error) {
	snapshot, err := s.store.Load(ctx, s.manifest, s.workspace)
	return pluginservice.SettingsEditor{Snapshot: snapshot}, err
}
func (s settingsFormSource) Save(ctx context.Context, editor pluginservice.SettingsEditor, scope string, edits []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	return s.store.Save(ctx, editor.Snapshot, scope, edits, nil)
}

func TestPluginSettingsFormEditsOnlyOnExplicitSaveAndPreservesConflictDraft(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(fixture.Manifest, &manifest); err != nil {
		t.Fatal(err)
	}
	// Three short rows keep every tested control visible; the real Core still
	// validates the manifest and owns all settings/document semantics.
	manifest["settings"] = json.RawMessage(`[{"id":"count","type":"integer","title":"Count","default":3,"minimum":1,"maximum":10},{"id":"flag","type":"boolean","title":"Flag","default":true,"scope":"project"},{"id":"label","type":"text","title":"Label","default":"base","pattern":"[a-z]+","maxLength":4,"scope":"project"}]`)
	fixture.Manifest, err = json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	preferences := t.TempDir()
	source := settingsFormSource{store: pluginsettings.New(core.NewClient(), preferences), manifest: fixture.Manifest, workspace: t.TempDir()}
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "dev.example.settings", Name: "Settings", LatestVersion: "1.0.0"}}}}, nil
	}
	runtime := PluginRuntimeState{Running: true, Version: "1.0.0", Workspace: source.workspace}
	restartCalls := 0
	w := newWindow(NewController(Options{
		PluginRuntime: func(string) PluginRuntimeState { return runtime },
		RestartPlugin: func(id, version, scope, workspace string) {
			if id != "dev.example.settings" || version != "1.0.0" || scope != "global" || workspace != source.workspace {
				t.Errorf("restart retargeted captured owner: %s %s %s %s", id, version, scope, workspace)
			}
			restartCalls++
			runtime.RestartRequired = false
		}, Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source, PluginState: func(string) PluginState { return PluginState{Installed: true} }}), Values{})
	w.sess.page = pagePlugins
	w.market.detailTab = detailSettings
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	words := func(key string) string { return i18n.Shared(i18n.English, "desktop.pluginSettings."+key) }
	wait := func(done func() bool) {
		t.Helper()
		d.until("the settings form", func() bool {
			if w.pluginSettings.failed != nil && !w.pluginSettings.running && !done() {
				t.Fatalf("form failed before ready: %v", w.pluginSettings.failed)
			}
			return done()
		})
	}
	wait(func() bool { return w.pluginSettings.loaded })
	path := filepath.Join(preferences, "plugin-settings.json")
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("opening wrote settings: %v", err)
	}
	d.click("Count")
	if err := d.driver.SelectText(0, 1); err != nil {
		t.Fatal(err)
	}
	d.typeText("7")
	d.pump()
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("typing wrote settings: %v", err)
	}
	d.click(words("save"))
	wait(func() bool { return !w.pluginSettings.running })
	if w.pluginSettings.failed != nil {
		t.Fatal(w.pluginSettings.failed)
	}
	actual, err := source.Load(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if string(actual.Snapshot.State.Settings["count"]) != "7" {
		t.Fatalf("native field not saved: %+v", actual.Snapshot.State.Settings)
	}
	runtime.RestartRequired = true
	w.inv.Invalidate()
	d.pump()
	if restartCalls != 0 {
		t.Fatal("saving restarted without an explicit click")
	}
	d.click(words("restart"))
	if restartCalls != 1 {
		t.Fatal("restart button did not hand off exactly one request")
	}
	// Reset is also a draft. A disk conflict must preserve it for the user.
	d.click(words("reset"))
	if err := os.WriteFile(path, []byte(`{"dev.example.settings":{"count":9}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	d.click(words("save"))
	wait(func() bool { return !w.pluginSettings.running })
	if w.pluginSettings.failed == nil || !w.pluginSettings.hasDraft() {
		t.Fatalf("conflict discarded reset draft: %v", w.pluginSettings.failed)
	}
	persisted, err := os.ReadFile(path)
	if err != nil || string(persisted) != `{"dev.example.settings":{"count":9}}` {
		t.Fatalf("conflict overwrote external source: %s %v", persisted, err)
	}
	d.click(words("discardReload"))
	wait(func() bool { return !w.pluginSettings.running })
	if w.pluginSettings.hasDraft() || w.pluginSettings.controls[0][0].text != "9" {
		t.Fatal("reload did not replace the conflicting draft")
	}

	// The integer declaration is global-only. Switching scope must create a
	// genuinely read-only input, not just dim a writable field.
	d.click(words("scope"))
	d.click(words("project"))
	d.pump()
	field := d.hit("Count")
	if !field.ReadOnly {
		t.Fatal("global-only project value is still natively editable")
	}
	d.clickHit(field)
	if err := d.driver.Type("10"); !errors.Is(err, app.ErrNoTextInput) {
		t.Fatalf("read-only input accepted native typing: %v", err)
	}
	if w.pluginSettings.hasDraft() || w.pluginSettings.controls[1][0].text != "9" {
		t.Fatal("read-only input changed the project draft")
	}
}
