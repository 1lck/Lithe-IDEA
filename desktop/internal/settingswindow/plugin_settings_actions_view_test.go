package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
)

type headlessActionSource struct {
	settingsFormSource
	calls chan bool
}

func (s headlessActionSource) Action(ctx context.Context, editor pluginservice.SettingsEditor, id string, confirmed bool) (pluginservice.SettingsActionResult, error) {
	s.calls <- confirmed
	plan, err := core.NewClient().PlanPluginSettingsAction(ctx, core.PluginSettingsActionRequest{Manifest: s.manifest, Owner: core.PluginSettingsOwner{PluginID: editor.Snapshot.State.PluginID, Version: editor.Snapshot.State.Metadata.Version}, ActionID: id, Confirmed: confirmed, Enabled: true, WorkspaceAvailable: true})
	return pluginservice.SettingsActionResult{Plan: plan, Completed: err == nil && plan.Kind == "invoke"}, err
}

func TestSettingsActionButtonsConfirmDismissAndPreserveUnsavedInput(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Manifest["settings"] = []any{map[string]any{"id": "count", "type": "integer", "title": "Count", "default": 3, "minimum": 1, "maximum": 10}}
	fixture.Manifest["settingActions"] = []any{map[string]any{"id": "refresh", "title": "Refresh fixture", "function": "snapshot.refresh", "confirm": true}}
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	preferences := t.TempDir()
	source := headlessActionSource{settingsFormSource: settingsFormSource{store: pluginsettings.New(core.NewClient(), preferences), manifest: manifest, workspace: t.TempDir()}, calls: make(chan bool, 4)}
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "dev.example.settings", Name: "Settings", LatestVersion: "1.0.0"}}}}, nil
	}
	w := newWindow(NewController(Options{PluginSettings: source, Marketplace: fetch, MarketplaceInstalled: fetch, PluginState: func(string) PluginState { return PluginState{Installed: true} }}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
	words := func(key string) string { return i18n.Shared(i18n.English, "desktop.pluginSettings."+key) }
	wait := func(done func() bool) {
		t.Helper()
		d.until("the action form", func() bool {
			if w.pluginSettings.failed != nil {
				t.Fatal(w.pluginSettings.failed)
			}
			return done()
		})
	}
	wait(func() bool { return w.pluginSettings.loaded })
	d.click("Count")
	if err := d.driver.SelectText(0, 1); err != nil {
		t.Fatal(err)
	}
	d.typeText("7")
	d.pump()
	d.click("Refresh fixture")
	wait(func() bool { return w.pluginSettings.actionConfirmation != nil })
	d.pump()
	// The confirmation is a modal: its question names the action, and Cancel dismisses it.
	if !d.has(words("actionContinue")) {
		t.Fatal("confirmation does not offer to continue")
	}
	d.click(words("actionCancel"))
	d.pump()
	if w.pluginSettings.actionConfirmation != nil || len(source.calls) != 1 {
		t.Fatal("dismissing confirmation invoked the action")
	}
	d.click("Refresh fixture")
	wait(func() bool { return w.pluginSettings.actionConfirmation != nil })
	d.pump()
	d.click(words("actionContinue"))
	wait(func() bool { return w.pluginSettings.actionComplete })
	for _, want := range []bool{false, false, true} {
		select {
		case got := <-source.calls:
			if got != want {
				t.Fatalf("confirmation sequence: %v want %v", got, want)
			}
		default:
			t.Fatal("missing action request")
		}
	}
	if w.pluginSettings.controls[0][0].text != "7" || !w.pluginSettings.hasDraft() {
		t.Fatal("action discarded the unsaved input")
	}
	if _, err := os.Stat(filepath.Join(preferences, "plugin-settings.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("action saved preferences: %v", err)
	}
}
