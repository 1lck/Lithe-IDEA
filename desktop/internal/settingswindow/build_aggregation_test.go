package settingswindow

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

// Build, Execution, Deployment gathers a plugin's build settings in one more place: the plugin's
// own Settings tab keeps every setting, the page placed under Build shows the placed ones, and
// both edit one draft.
func TestBuildPageGathersSettingsThePluginKeepsInItsOwnTab(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	const pluginID = "dev.example.settings"
	fixture.Manifest["id"] = pluginID
	fixture.Manifest["settings"] = []any{
		map[string]any{"id": "count", "type": "integer", "title": "Count", "default": 3, "minimum": 1, "maximum": 10},
		map[string]any{"id": "flag", "type": "boolean", "title": "Flag", "default": true, "page": map[string]string{"buildSystemID": "bs"}, "section": "Options"},
	}
	delete(fixture.Manifest, "settingActions")
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	contributions := []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: pluginID, Version: "1.0.0"}, Enabled: true}}
	source := settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: pluginID, Name: "Settings", LatestVersion: "1.0.0"}}}}, nil
	}
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, Language: func() i18n.Language { return i18n.English },
		PluginSettings: source, Marketplace: fetch, MarketplaceInstalled: fetch,
		PluginState: func(string) PluginState { return PluginState{Installed: true} },
		InstalledPlugins: func() []PluginFacts {
			return []PluginFacts{{ID: pluginID, Name: "Settings", Version: "1.0.0", Settings: 2}}
		},
		SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, contributions, "")
		},
	}), Values{})
	w.sess.page = pagePlugins
	w.installed.tab = installedSettings
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	loaded := func(what string) {
		t.Helper()
		d.until(what, func() bool {
			if w.pluginSettings.failed != nil {
				t.Fatal(w.pluginSettings.failed)
			}
			return w.pluginSettings.loaded && w.dynamic.loaded
		})
		d.pump()
	}
	loaded("the plugin's own settings")
	if !d.has("Count") || !d.has("Flag") {
		t.Fatal("the plugin's Settings tab must keep every setting, the one placed under Build too")
	}
	d.click("Count")
	if err := d.driver.SelectText(0, 1); err != nil {
		t.Fatal(err)
	}
	d.typeText("7")
	d.pump()
	if !w.pluginSettings.hasDraft() {
		t.Fatal("editing Count in the plugin's tab made no draft")
	}

	w.openContributedPage("buildSystem:bs", pluginID)
	d.until("the page under Build", func() bool { return w.pluginSettings.pageKey == "buildSystem:bs" && w.dynamic.loaded })
	d.pump()
	if !d.has("Flag") {
		t.Fatal("the page under Build must show the setting placed there")
	}
	if d.has("Count") {
		t.Fatal("the page under Build shows only the settings placed there")
	}
	if !w.pluginSettings.hasDraft() {
		t.Fatal("the page under Build edits the plugin's own form, so the draft made in its tab is kept")
	}
}
