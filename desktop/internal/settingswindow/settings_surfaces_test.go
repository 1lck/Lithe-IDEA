package settingswindow

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func TestSettingsDynamicPagesShareDraftsFilterActionsAndRefreshCleanForms(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
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

// flagsManifest is the settings fixture's manifest with count boolean settings, all placed on
// the elixir language page, and no actions.
func flagsManifest(t *testing.T, count int) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	settings := make([]any, 0, count)
	for index := range count {
		settings = append(settings, map[string]any{"id": fmt.Sprintf("flag%02d", index), "type": "boolean", "title": fmt.Sprintf("Flag %02d", index), "default": true, "page": map[string]string{"languageID": "elixir"}})
	}
	fixture.Manifest["settings"] = settings
	delete(fixture.Manifest, "settingActions")
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	return manifest
}

// settingsListFit is where a form's settings list sits in the window once the page is
// scrolled to its end: its visible height and the distance from its bottom to the top of the
// window's OK button.
type settingsListFit struct{ height, gap float32 }

// settingsListHits are the open form's settings list, as much of it as is visible, and the
// window's OK button.
func settingsListHits(t *testing.T, d *windowDriver, w *window) (list, ok gfx.Hit) {
	t.Helper()
	for _, hit := range d.driver.Snapshot().Hits {
		switch {
		case hit.Role == gfx.RoleListBox && hit.Label == i18n.Shared(i18n.English, "desktop.pluginSettings.title"):
			list = hit
		case hit.Role == gfx.RoleButton && hit.Label == w.text.Settings.OK:
			ok = hit
		}
	}
	if list.Bounds.Height == 0 || ok.Bounds.Height == 0 {
		t.Fatal("no settings list or no OK button")
	}
	return list, ok
}

// measureSettingsList scrolls the page to its end, measures the open form's list, then
// scrolls the list to its last row and fails unless that row is drawn whole inside it.
func measureSettingsList(t *testing.T, d *windowDriver, w *window, last string) settingsListFit {
	t.Helper()
	list, _ := settingsListHits(t, d, w)
	// The wheel turns just above the list, so it scrolls the page and not the list's rows.
	if err := d.driver.Scroll(gfx.ScrollEvent{X: list.Bounds.X + list.Bounds.Width/2, Y: list.Bounds.Y - 4, DeltaY: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	d.pump()
	list, ok := settingsListHits(t, d, w)
	bottom := list.Bounds.Y + list.Bounds.Height
	w.pluginSettings.rows.ScrollTo(len(w.pluginSettings.layout)-1, ui.ListEnd)
	w.inv.Invalidate()
	d.pump()
	d.pump()
	found := false
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value != last {
			continue
		}
		found = true
		if label.Bounds.Y < list.Bounds.Y || label.Bounds.Y+label.Bounds.Height > bottom {
			t.Fatalf("the last row %+v is cut by the list %+v", label.Bounds, list.Bounds)
		}
	}
	if !found {
		t.Fatalf("the last row %q is not drawn", last)
	}
	return settingsListFit{height: list.Bounds.Height, gap: ok.Bounds.Y - bottom}
}

// settingsListHeights are the window heights the list is measured in: the smallest window,
// which scrolls the page to show the list's least height, and two that it fills.
var settingsListHeights = [3]int{windowMinHeight, 800, 1000}

// checkSettingsListFills fails unless, in the two taller windows, the list grew by exactly what
// the window grew and ends the same short distance above the window's buttons, and, in the
// smallest, the page scrolls to the whole of the list's least height above the buttons.
func checkSettingsListFills(t *testing.T, fits map[int]settingsListFit) {
	t.Helper()
	small, mid, tall := fits[settingsListHeights[0]], fits[settingsListHeights[1]], fits[settingsListHeights[2]]
	grown := float32(settingsListHeights[2] - settingsListHeights[1])
	if delta := tall.height - mid.height; delta < grown-1 || delta > grown+1 {
		t.Fatalf("the list grew %v for a window %v taller: %+v, %+v", delta, grown, mid, tall)
	}
	if tall.gap-mid.gap > 1 || mid.gap-tall.gap > 1 || mid.gap < 0 || tall.gap > 3*contentPad {
		t.Fatalf("the list does not end at the page's bottom: %+v, %+v", mid, tall)
	}
	if small.height < settingsListMinHeight-1 || small.gap < 0 {
		t.Fatalf("the smallest window shows %+v of the list", small)
	}
}

// A language page's settings list fills the page under the form's header, so the last row ends
// at the page's bottom instead of being cut off at a fixed height above blank space, and a
// window too short for the list scrolls the page.
func TestSettingsDynamicPageListFillsThePageAndShowsItsLastRowWhole(t *testing.T) {
	const count = 30
	manifest := flagsManifest(t, count)
	fits := map[int]settingsListFit{}
	for _, height := range settingsListHeights {
		client := core.NewClient()
		source := settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}
		w := newWindow(NewController(Options{PluginSettings: source, Text: func() *i18n.Messages { return i18n.For(i18n.English) }, SettingsNavigation: client.SettingsNavigation, SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings", Version: "1.0.0"}, Enabled: true}})
		}}), Values{Theme: "dark"})
		d := openWindow(t, w, func(config *app.Config) { config.Height = height })
		d.until("the language page", func() bool { return len(w.dynamic.pages) == 1 })
		w.selectSettingsPage(pageLanguages, w.dynamic.pages[0].Key)
		d.until("the form", func() bool { return w.pluginSettings != nil && w.pluginSettings.loaded && !w.pluginSettings.running })
		w.inv.Invalidate()
		d.pump()
		fits[height] = measureSettingsList(t, d, w, fmt.Sprintf("Flag %02d", count-1))
	}
	checkSettingsListFills(t, fits)
}
