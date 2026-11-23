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
	w := newWindow(NewController(Options{SettingsError: func(string, error) { warnings.Add(1) }, PluginSettings: source, Text: func() *i18n.Messages { return i18n.For(i18n.English) }, SettingsNavigation: client.SettingsNavigation, SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
		return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings", Version: "1.0.0"}, Enabled: enabled}, {Manifest: otherManifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings-other", Version: "1.0.0"}, Enabled: secondEnabled}}, "")
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
	findRow := func(dynamic string) (row, bool) {
		for _, r := range w.rows {
			if r.page == pageLanguages && r.dynamic == dynamic {
				return r, true
			}
		}
		return row{}, false
	}
	// The plugin's page makes Languages & Frameworks a group, collapsed until it is opened.
	wait(func() bool { r, ok := findRow(""); return ok && r.group })
	if languages, _ := findRow(""); languages.expanded {
		t.Fatalf("Languages & Frameworks starts expanded: %+v", languages)
	}
	if r, ok := findRow(key); ok {
		t.Fatalf("collapsed Languages & Frameworks lists the plugin's page: %+v", r)
	}
	// The group keeps a page of its own, which its row opens and shows selected.
	w.selectSettingsPage(pageLanguages, "")
	for i, r := range w.rows {
		if r.page == pageLanguages && r.dynamic == "" {
			if node := w.navNode(i); !node.Branch || !node.Selected {
				t.Fatalf("Languages & Frameworks row with its page open = %+v, want a selected branch", node)
			}
		}
	}
	// Opening the plugin's page expands the group it is in, so its row is on the screen.
	w.selectSettingsPage(pageLanguages, key)
	wait(func() bool { _, ok := findRow(key); return ok })
	if r, _ := findRow(key); r.level != 1 {
		t.Fatalf("dynamic row=%+v", r)
	}
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

func (s dynamicFormsSource) Load(ctx context.Context, id string, _ i18n.Language) (pluginservice.SettingsEditor, error) {
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

// settingsOKButton is the window's OK button.
func settingsOKButton(t *testing.T, d *windowDriver, w *window) gfx.Hit {
	t.Helper()
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleButton && hit.Label == w.text.Settings.OK {
			return hit
		}
	}
	t.Fatal("no OK button")
	return gfx.Hit{}
}

// settingsRowLabel is the drawn title of the form row whose words are value. It fails unless
// the row is drawn and nothing cuts it from above or below, which a scroll of the form's own
// would once the page is at its end.
func settingsRowLabel(t *testing.T, d *windowDriver, value string) app.Label {
	t.Helper()
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value != value {
			continue
		}
		if label.Clipped && (label.Bounds.Y < label.Clip.Y-0.5 || label.Bounds.Y+label.Bounds.Height > label.Clip.Y+label.Clip.Height+0.5) {
			t.Fatalf("the row %q at %+v is cut by %+v", value, label.Bounds, label.Clip)
		}
		return label
	}
	t.Fatalf("the row %q is not drawn", value)
	return app.Label{}
}

// wheelOverSettingsRow turns the wheel by delta over a form row, where a scroll of the form's
// own would take the wheel instead of passing it to the page.
func wheelOverSettingsRow(t *testing.T, d *windowDriver, row app.Label, delta float32) {
	t.Helper()
	at := row.Bounds
	if err := d.driver.Scroll(gfx.ScrollEvent{X: at.X + at.Width/2, Y: at.Y + at.Height/2, DeltaY: delta, Precise: true}); err != nil {
		t.Fatal(err)
	}
	d.pump()
}

// measureSettingsForm fails unless the form has no scroll of its own and the wheel over its
// rows carries the page from its first row to its last, both drawn whole. It returns the
// distance from the last row's bottom to the top of the window's OK button, which says the
// page stops at the end of its content rather than at a height the form chose.
func measureSettingsForm(t *testing.T, d *windowDriver, w *window, first, last string) float32 {
	t.Helper()
	title := i18n.Shared(i18n.English, "desktop.pluginSettings.title")
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleListBox && hit.Label == title {
			t.Fatalf("the form declares a scroll of its own at %+v", hit.Bounds)
		}
	}
	wheelOverSettingsRow(t, d, settingsRowLabel(t, d, first), 10000)
	row := settingsRowLabel(t, d, last)
	ok := settingsOKButton(t, d, w)
	bottom := row.Bounds.Y + row.Bounds.Height
	if bottom > ok.Bounds.Y {
		t.Fatalf("the last row at %+v is under the window's buttons at %v", row.Bounds, ok.Bounds.Y)
	}
	// The wheel back up over the rows brings the first row back, whole.
	wheelOverSettingsRow(t, d, row, -10000)
	settingsRowLabel(t, d, first)
	return ok.Bounds.Y - bottom
}

// settingsFormHeights are the window heights the form is measured in: the smallest window and
// two taller ones, all of them shorter than the 30 rows the form holds.
var settingsFormHeights = [3]int{windowMinHeight, 800, 1000}

// checkSettingsFormEnds fails unless the page ends the same short distance under the form's
// last row whatever the window's height. The form scrolls with the page, so the page's end is
// the end of the form's rows and not a height the form kept for itself.
func checkSettingsFormEnds(t *testing.T, gaps map[int]float32) {
	t.Helper()
	small, mid, tall := gaps[settingsFormHeights[0]], gaps[settingsFormHeights[1]], gaps[settingsFormHeights[2]]
	for _, gap := range [3]float32{small, mid, tall} {
		if gap < 0 || gap > 3*contentPad {
			t.Fatalf("the page does not end under the last row: %v, %v, %v", small, mid, tall)
		}
	}
	if tall-mid > 1 || mid-tall > 1 || mid-small > 1 || small-mid > 1 {
		t.Fatalf("the page's end moved with the window's height: %v, %v, %v", small, mid, tall)
	}
}

// A language page's form scrolls with the page it sits in, so the wheel over its rows carries
// the page from the first row to the last with both drawn whole, whatever the window's height.
// A scroll of the form's own would take only the height what sits above it leaves, and cut its
// rows off once the page itself was at its end.
func TestSettingsDynamicPageFormScrollsWithThePageAndShowsItsRowsWhole(t *testing.T) {
	const count = 30
	manifest := flagsManifest(t, count)
	gaps := map[int]float32{}
	for _, height := range settingsFormHeights {
		client := core.NewClient()
		source := settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}
		w := newWindow(NewController(Options{PluginSettings: source, Text: func() *i18n.Messages { return i18n.For(i18n.English) }, SettingsNavigation: client.SettingsNavigation, SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings", Version: "1.0.0"}, Enabled: true}}, "")
		}}), Values{Theme: "dark"})
		d := openWindow(t, w, func(config *app.Config) { config.Height = height })
		d.until("the language page", func() bool { return len(w.dynamic.pages) == 1 })
		w.selectSettingsPage(pageLanguages, w.dynamic.pages[0].Key)
		d.until("the form", func() bool { return w.pluginSettings != nil && w.pluginSettings.loaded && !w.pluginSettings.running })
		w.inv.Invalidate()
		d.pump()
		gaps[height] = measureSettingsForm(t, d, w, "Flag 00", fmt.Sprintf("Flag %02d", count-1))
	}
	checkSettingsFormEnds(t, gaps)
}
