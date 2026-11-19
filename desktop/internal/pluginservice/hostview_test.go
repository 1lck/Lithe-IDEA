package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// viewParams is what viewEvent sends for call, by key.
func viewParams(t *testing.T, s *Service, call ViewCall) map[string]json.RawMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	data, err := s.viewEvent(ctx, call)
	if err != nil {
		t.Fatal(err)
	}
	var params map[string]json.RawMessage
	if err := json.Unmarshal(data, &params); err != nil {
		t.Fatal(err)
	}
	return params
}

// viewSettingsOf is the settings params carried.
func viewSettingsOf(t *testing.T, params map[string]json.RawMessage) ViewSettings {
	t.Helper()
	var settings ViewSettings
	if err := json.Unmarshal(params["settings"], &settings); err != nil {
		t.Fatalf("settings %s: %v", params["settings"], err)
	}
	return settings
}

// A settings page's event keeps the settings it carries, the draft with them, and gains the
// surface it is shown on.
func TestViewEventKeepsTheSettingsThePageSent(t *testing.T) {
	s := &Service{Settings: pluginsettings.New(core.NewClient(), t.TempDir())}
	params := viewParams(t, s, ViewCall{
		Manifest: json.RawMessage(`{}`),
		Surface:  core.PluginViewSurface{SettingRegionID: "overview"},
		Event:    json.RawMessage(`{"event":"click","node":"probe","settings":{"effective":{"threads":4},"draft":{"threads":8}}}`),
	})
	if string(params["event"]) != `"click"` || string(params["node"]) != `"probe"` {
		t.Fatalf("the event's own params changed: %v", params)
	}
	var surface core.PluginViewSurface
	if err := json.Unmarshal(params["surface"], &surface); err != nil || surface.SettingRegionID != "overview" {
		t.Fatalf("surface %s, %v", params["surface"], err)
	}
	settings := viewSettingsOf(t, params)
	if string(settings.Effective["threads"]) != `4` || string(settings.Draft["threads"]) != `8` {
		t.Fatalf("the page's settings were replaced: %+v", settings)
	}
}

// A tool window's event carries the saved values in force with an empty draft: none for a
// host without a settings store, and Core's projection of the manifest's settings otherwise.
func TestViewEventAddsTheSavedSettingsForAToolWindow(t *testing.T) {
	bare := viewSettingsOf(t, viewParams(t, &Service{}, ViewCall{Event: json.RawMessage(`{"event":"open"}`)}))
	if bare.Effective == nil || len(bare.Effective) != 0 || bare.Draft == nil || len(bare.Draft) != 0 {
		t.Fatalf("a host without a settings store sent %+v", bare)
	}

	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	s := &Service{Settings: pluginsettings.New(core.NewClient(), t.TempDir())}
	params := viewParams(t, s, ViewCall{
		Manifest: manifest, Workspace: t.TempDir(),
		Surface: core.PluginViewSurface{ToolWindowID: "fixture.tool"},
		Event:   json.RawMessage(`{"event":"open"}`),
	})
	settings := viewSettingsOf(t, params)
	for _, id := range []string{"dialyzer", "checks"} {
		if len(settings.Effective[id]) == 0 {
			t.Errorf("the saved value of %s is not carried: %v", id, settings.Effective)
		}
	}
	if settings.Draft == nil || len(settings.Draft) != 0 {
		t.Fatalf("a tool window carried the drafts %v", settings.Draft)
	}
}

// Settings that cannot be read fail the event, except a close, which still reaches the
// backend so the view's state ends.
func TestViewEventFailsWithoutTheSettingsUnlessItCloses(t *testing.T) {
	s := &Service{Settings: pluginsettings.New(core.NewClient(), t.TempDir())}
	call := ViewCall{Manifest: json.RawMessage(`{"not":"a manifest"}`), Event: json.RawMessage(`{"event":"open"}`)}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if _, err := s.viewEvent(ctx, call); err == nil {
		t.Fatal("an event went out without the settings it could not read")
	}
	call.Event, call.Close = json.RawMessage(`{"event":"close"}`), true
	params := viewParams(t, s, call)
	if string(params["event"]) != `"close"` {
		t.Fatalf("the close event = %v", params)
	}
	if settings, ok := params["settings"]; ok {
		t.Fatalf("a close carried settings it could not read: %s", settings)
	}
}

func TestViewEventRefusesParamsThatAreNotAnObject(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if _, err := (&Service{}).viewEvent(ctx, ViewCall{Event: json.RawMessage(`["open"]`)}); err == nil {
		t.Fatal("a list was sent as an event's params")
	}
}
