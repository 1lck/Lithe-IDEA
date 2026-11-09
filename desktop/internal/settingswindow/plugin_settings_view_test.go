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
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
				t.Fatalf("restart retargeted captured owner: %s %s %s %s", id, version, scope, workspace)
			}
			restartCalls++
			runtime.RestartRequired = false
		}, Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source, PluginState: func(string) PluginState { return PluginState{Installed: true} }}), Values{})
	w.sess.page = pagePlugins
	config := w.config()
	config.Height = 1100
	driver, err := app.NewDriver(config, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.pluginSettings.close(); w.market.close(); driver.Close() })
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	pump := func() {
		t.Helper()
		w.inv.Invalidate()
		if err := driver.Pump(); err != nil {
			t.Fatal(err)
		}
	}
	wait := func(done func() bool) {
		t.Helper()
		pump()
		for !done() {
			if w.pluginSettings.failed != nil && !w.pluginSettings.running {
				t.Fatalf("form failed before ready: %v", w.pluginSettings.failed)
			}
			select {
			case <-driver.Wakes():
				pump()
			case <-timer.C:
				t.Fatalf("settings form did not finish: loaded=%v running=%v error=%v", w.pluginSettings.loaded, w.pluginSettings.running, w.pluginSettings.failed)
			}
		}
	}
	click := func(id gfx.ID) {
		t.Helper()
		pump()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		t.Fatalf("control %v not visible", id)
	}
	wait(func() bool { return w.pluginSettings.loaded })
	path := filepath.Join(preferences, "plugin-settings.json")
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("opening wrote settings: %v", err)
	}
	click(pluginSettingRows.At(0))
	if err := driver.SelectText(0, 1); err != nil {
		t.Fatal(err)
	}
	if err := driver.Type("7"); err != nil {
		t.Fatal(err)
	}
	pump()
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("typing wrote settings: %v", err)
	}
	click(pluginSettingsSave)
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
	pump()
	if restartCalls != 0 {
		t.Fatal("saving restarted without an explicit click")
	}
	click(pluginSettingsRestart)
	if restartCalls != 1 {
		t.Fatal("restart button did not hand off exactly one request")
	}
	// Reset is also a draft. A disk conflict must preserve it for the user.
	click(pluginSettingRows.At(1))
	if err := os.WriteFile(path, []byte(`{"dev.example.settings":{"count":9}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	click(pluginSettingsSave)
	wait(func() bool { return !w.pluginSettings.running })
	if w.pluginSettings.failed == nil || !w.pluginSettings.hasDraft() {
		t.Fatalf("conflict discarded reset draft: %v", w.pluginSettings.failed)
	}
	persisted, err := os.ReadFile(path)
	if err != nil || string(persisted) != `{"dev.example.settings":{"count":9}}` {
		t.Fatalf("conflict overwrote external source: %s %v", persisted, err)
	}
	click(pluginSettingsReload)
	wait(func() bool { return !w.pluginSettings.running })
	if w.pluginSettings.hasDraft() || w.pluginSettings.controls[0][0].field.Text() != "9" {
		t.Fatal("reload did not replace the conflicting draft")
	}

	// The integer declaration is global-only. Switching scope must create a
	// genuinely read-only native input, not just dim a writable Field.
	click(pluginSettingsScope.At(2))
	click(pluginSettingsScope.At(1))
	pump()
	found := false
	for _, hit := range driver.Snapshot().Hits {
		if hit.ID == pluginSettingRows.At(0) {
			found = true
			if !hit.ReadOnly {
				t.Fatal("global-only project value is still natively editable")
			}
		}
	}
	if !found {
		t.Fatal("read-only inherited value is absent")
	}
	click(pluginSettingRows.At(0))
	if err := driver.Type("10"); !errors.Is(err, app.ErrNoTextInput) {
		t.Fatalf("read-only input accepted native typing: %v", err)
	}
	if w.pluginSettings.hasDraft() || w.pluginSettings.controls[1][0].field.Text() != "9" {
		t.Fatal("read-only input changed the project draft")
	}
}
