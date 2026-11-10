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
	config := w.config()
	config.Height = 1100
	driver, err := app.NewDriver(config, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		w.pluginSettings.close()
		w.market.close()
		if w.pluginSettings.running {
			select {
			case <-w.pluginSettings.results:
			case <-time.After(5 * time.Second):
				t.Error("action worker did not terminate")
			}
		}
		driver.Close()
	})
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
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
			if w.pluginSettings.failed != nil {
				t.Fatal(w.pluginSettings.failed)
			}
			select {
			case <-driver.Wakes():
				pump()
			case <-deadline.C:
				t.Fatal("action form did not reach its expected state")
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
		t.Fatalf("action control %v is not visible", id)
	}
	wait(func() bool { return w.pluginSettings.loaded })
	click(pluginSettingRows.At(0))
	if err := driver.SelectText(0, 1); err != nil {
		t.Fatal(err)
	}
	if err := driver.Type("7"); err != nil {
		t.Fatal(err)
	}
	pump()
	click(pluginSettingActions.At(0))
	wait(func() bool { return w.pluginSettings.actionConfirmation != nil })
	click(pluginSettingActionDismiss)
	pump()
	if w.pluginSettings.actionConfirmation != nil || len(source.calls) != 1 {
		t.Fatal("dismissing confirmation invoked the action")
	}
	click(pluginSettingActions.At(0))
	wait(func() bool { return w.pluginSettings.actionConfirmation != nil })
	click(pluginSettingActionConfirm)
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
	if w.pluginSettings.controls[0][0].field.Text() != "7" || !w.pluginSettings.hasDraft() {
		t.Fatal("action discarded the unsaved input")
	}
	if _, err := os.Stat(filepath.Join(preferences, "plugin-settings.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("action saved preferences: %v", err)
	}
}
