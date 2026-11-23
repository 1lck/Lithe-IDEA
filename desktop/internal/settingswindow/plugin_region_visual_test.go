//go:build vivahead && lithevisual

package settingswindow

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
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/headless"
)

// viewPanelManifest is the contract's view-panel fixture with settings a region binds: one of
// each kind the view's controls edit and one the host draws as its own row.
func viewPanelManifest(t *testing.T) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(contractfixture.Path("fixtures/ui/view-panel.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	manifest["settings"] = json.RawMessage(`[
		{"id":"mode","type":"enum","title":"Mode","default":"fast","options":[{"value":"fast","title":"Fast"},{"value":"full","title":"Full"}]},
		{"id":"watch","type":"boolean","title":"Watch files","default":true},
		{"id":"name","type":"text","title":"Name","default":"core","pattern":"[a-z][a-z0-9-]*","maxLength":32},
		{"id":"threads","type":"integer","title":"Threads","default":4,"minimum":1,"maximum":64}]`)
	data, err = json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// regionViewSource is the settings store over the view-panel fixture, its region drawn from view.
type regionViewSource struct {
	settingsFormSource
	view json.RawMessage
}

func (s regionViewSource) View(context.Context, pluginservice.SettingsEditor, string, string, json.RawMessage, json.RawMessage, bool) (json.RawMessage, bool, error) {
	return s.view, true, nil
}

// visualRegionView is a settings region that binds declared settings, shows the host's row
// for one setting and the picker of one tool, and draws a summary on a canvas.
func visualRegionView() json.RawMessage {
	view, _ := json.Marshal([]map[string]any{
		{"type": "banner", "tone": "accent", "text": "These settings apply to every project the plugin indexes."},
		{"type": "segmented", "id": "mode", "label": "Mode", "setting": "mode"},
		{"type": "toggle", "id": "watch", "label": "Watch files", "setting": "watch"},
		{"type": "textField", "id": "name", "label": "Name", "setting": "name", "width": 24},
		{"type": "setting", "setting": "threads"},
		{"type": "tool", "tool": fixtureTool, "choose": true},
		{"type": "keyValue", "items": []map[string]any{
			{"label": "Indexed", "value": "1,284 files"},
			{"label": "Last check", "value": "Passed", "tone": "success"},
		}},
		{"type": "canvas", "id": "coverage", "label": "Index coverage", "height": 56, "viewBox": []int{0, 0, 560, 56}, "nodes": []map[string]any{
			{"type": "rect", "x": 0, "y": 0, "w": 560, "h": 56, "radius": 8, "fill": "$surface", "stroke": "$line"},
			{"type": "text", "x": 14, "y": 22, "text": "Index coverage", "style": "caption", "color": "$textSecondary"},
			{"type": "rect", "x": 14, "y": 32, "w": 532, "h": 10, "radius": 5, "fill": "$badge"},
			{"type": "rect", "x": 14, "y": 32, "w": 420, "h": 10, "radius": 5, "fill": "$accent"},
			{"type": "text", "x": 546, "y": 22, "text": "79%", "style": "strong", "align": "end"},
		}},
	})
	return view
}

// TestVisualPluginRegion renders the view-panel fixture's Settings tab with its region, then with
// the tool row's choices open, in English and Chinese and in the dark and the light theme. Opt in with
// -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualPluginRegion(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture a plugin settings region")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	manifest := viewPanelManifest(t)
	fetch := func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: viewPanelPlugin, Name: "View Panel", LatestVersion: "1.0.0"}}}}, nil
	}
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"/"+theme, func(t *testing.T) {
				// The preference directory does not exist, so the page reads the defaults and shows
				// a fixed path rather than the machine's temporary directory; nothing here saves.
				source := regionViewSource{
					settingsFormSource: settingsFormSource{store: pluginsettings.New(core.NewClient(), "/fixture/preferences"), manifest: manifest, workspace: t.TempDir()},
					view:               visualRegionView(),
				}
				// Core validates the manifest; a rule it adds would otherwise show only as a window
				// that never draws the region.
				if _, err := source.Load(context.Background(), viewPanelPlugin, language); err != nil {
					t.Fatalf("Core did not load the view-panel fixture's settings: %v", err)
				}
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemDark:  func() bool { return theme == "dark" },
					Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source,
					Toolchains:  &scopedToolchainLoader{fakeToolchainLoader{snapshot: globalVisualToolchains()}},
					PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
					InstalledPlugins: func() []PluginFacts {
						return []PluginFacts{{ID: viewPanelPlugin, Name: "View Panel", Vendor: "Example", Version: "1.0.0", Settings: 4}}
					},
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.page = pagePlugins
				w.installed.tab = installedSettings
				config := w.config()
				config.Height = 1180
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.until("the region's view and the tool row", func() bool {
					return d.text("Indexed") && d.has("Compiler") && d.has("Fast")
				})
				d.pump()
				if err := session.Screenshot(filepath.Join(out, "plugin-settings-region-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
				d.click("Compiler")
				manage := i18n.Shared(language, "desktop.pluginView.toolPickerToolchains")
				d.until("the tool's choices", func() bool { return d.has(manage) && d.has("/fixture/sdk8") })
				d.pump()
				// The choices fade in; the capture waits for them to finish.
				if err := session.Advance(300 * time.Millisecond); err != nil {
					t.Fatal(err)
				}
				if err := session.Screenshot(filepath.Join(out, "plugin-settings-tool-picker-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
