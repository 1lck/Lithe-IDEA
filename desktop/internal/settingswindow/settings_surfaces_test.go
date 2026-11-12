package settingswindow

import (
	"context"
	"encoding/json"
	"os"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

func TestSettingsDynamicPagesShareDraftsFilterActionsAndRefreshCleanForms(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Manifest["settings"] = []any{
		map[string]any{"id": "count", "type": "integer", "title": "Count", "default": 3, "minimum": 1, "maximum": 10, "page": map[string]string{"languageID": "elixir"}, "section": "Server"},
		map[string]any{"id": "flag", "type": "boolean", "title": "Flag", "default": true},
	}
	fixture.Manifest["settingActions"] = []any{
		map[string]any{"id": "local", "title": "Only plugin", "function": "fixture.local"},
		map[string]any{"id": "placed", "title": "Placed action", "function": "fixture.placed", "page": map[string]string{"languageID": "elixir"}},
	}
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	fixture.Manifest["id"] = "dev.example.settings-other"
	otherManifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	source := dynamicFormsSource{settingsFormSource: settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}, other: otherManifest}
	secondEnabled := true
	enabled := true
	var warnings atomic.Int32
	w := newWindow(NewController(Options{SettingsError: func(error) { warnings.Add(1) }, PluginSettings: source, Text: func() *i18n.Messages { return i18n.For(i18n.English) }, SettingsNavigation: client.SettingsNavigation, SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
		return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings", Version: "1.0.0"}, Enabled: enabled}, {Manifest: otherManifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings-other", Version: "1.0.0"}, Enabled: secondEnabled}})
	}}), Values{Theme: "dark"})
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	pump := func() {
		t.Helper()
		w.inv.Invalidate()
		d.pump()
	}
	wait := func(done func() bool) {
		t.Helper()
		d.until("the settings surface", done)
	}
	wait(func() bool { return len(w.dynamic.pages) == 1 })
	key := w.dynamic.pages[0].Key
	found := false
	for _, row := range w.rows {
		if row.dynamic == key {
			found = true
			if row.page != pageLanguages || row.level != 1 {
				t.Fatalf("dynamic row=%+v", row)
			}
		}
	}
	if !found {
		t.Fatal("Core page absent from sidebar")
	}
	w.selectSettingsPage(pageLanguages, key)
	wait(func() bool { return w.pluginSettings.loaded })
	form := w.pluginSettings
	actions, rows := 0, 0
	for _, item := range form.layout {
		if item.action {
			actions++
			if form.editor.Snapshot.State.Actions[item.row].ID != "placed" {
				t.Fatal("unplaced action leaked")
			}
		} else if item.row >= 0 {
			rows++
			if item.row != 0 {
				t.Fatal("unplaced row leaked")
			}
		}
	}
	if actions != 1 || rows != 1 {
		t.Fatalf("placement layout=%+v", form.layout)
	}
	form.controls[0][0].text = "7"
	w.selectSettingsPage(pageGeneral, "")
	pump()
	w.selectSettingsPage(pageLanguages, key)
	pump()
	if w.pluginSettings != form || form.controls[0][0].text != "7" {
		t.Fatal("switching pages discarded draft/native input owner")
	}
	form.sourceChanged()
	form.sourceChanged()
	if warnings.Load() != 1 {
		t.Fatalf("source conflict warnings=%d", warnings.Load())
	}
	pump()
	if !form.stale || form.controls[0][0].text != "7" {
		t.Fatal("external publication overwrote dirty form")
	}
	form.save()
	if form.running {
		t.Fatal("stale form started a save")
	}
	form.load(form.id)
	wait(func() bool { return form.loaded && !form.running })
	if form.stale || form.controls[0][0].text != "3" {
		t.Fatal("explicit reload did not establish a new baseline")
	}
	form.sourceChanged()
	wait(func() bool { return form.loaded && !form.running })
	if form.stale {
		t.Fatal("clean form did not refresh")
	}
	// Registry change removes the page without deleting the cached form's draft.
	form.controls[0][0].text = "8"
	w.contributorID = "dev.example.settings-other"
	wait(func() bool { return w.pluginSettings.id == "dev.example.settings-other" && w.pluginSettings.loaded })
	if w.pluginSettings == form || form.controls[0][0].text != "8" {
		t.Fatal("contributor selection replaced another plugin's draft")
	}
	enabled = false
	w.pluginRegistryChanged.Store(true)
	pump()
	wait(func() bool {
		return len(w.dynamic.pages) == 1 && len(w.dynamic.pages[0].Contributors) == 1
	})
	pump()
	if w.contributionOf(w.dynamic.selected(w.dynamicPage)) != 0 || w.contributorID != "dev.example.settings-other" {
		t.Fatal("catalog refresh changed the stable contributor selection")
	}
	secondEnabled = false
	w.pluginRegistryChanged.Store(true)
	pump()
	wait(func() bool { return w.dynamic.loaded && len(w.dynamic.pages) == 0 })
	if form.controls[0][0].text != "8" {
		t.Fatal("disabled page silently discarded draft")
	}
}

// Each contributor resolves its own complete native source and declaration set.
type dynamicFormsSource struct {
	settingsFormSource
	other json.RawMessage
}

func (s dynamicFormsSource) Load(ctx context.Context, id string) (pluginservice.SettingsEditor, error) {
	manifest := s.manifest
	if id == "dev.example.settings-other" {
		manifest = s.other
	}
	snapshot, err := s.store.Load(ctx, manifest, s.workspace)
	return pluginservice.SettingsEditor{Snapshot: snapshot}, err
}
