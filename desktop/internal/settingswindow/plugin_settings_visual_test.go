//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/headless"
)

// pluginSettingsVisualDeclarations are five settings shaped like a language plugin's: a
// toolchain file on a build-system page, and switches and a choice on a language page.
const pluginSettingsVisualDeclarations = `[
{"id":"goExecutable","type":"file","title":"Go executable","description":"The go program used to read the module and to build, vet, test and run it. Leave empty to use go from PATH.","default":"","placeholder":"Automatic: go on PATH","effect":"reload","page":{"buildSystemID":"go"},"section":"Go toolchain"},
{"id":"staticcheck","type":"boolean","title":"Staticcheck analyses","description":"Report staticcheck's additional checks as diagnostics. Uses more CPU and memory on large modules.","default":false,"effect":"reload","page":{"languageID":"go"},"section":"gopls"},
{"id":"gofumpt","type":"boolean","title":"Format with gofumpt","description":"Apply gofumpt's stricter rules when formatting Go files.","default":false,"effect":"reload","page":{"languageID":"go"},"section":"gopls"},
{"id":"usePlaceholders","type":"boolean","title":"Parameter placeholders in completion","description":"Insert placeholders for a function's parameters when completing a call.","default":false,"effect":"reload","page":{"languageID":"go"},"section":"gopls"},
{"id":"hoverKind","type":"enum","title":"Hover documentation","description":"How much documentation a hover shows.","default":"FullDocumentation","effect":"reload","page":{"languageID":"go"},"section":"gopls","options":[{"value":"FullDocumentation","title":"Full documentation"},{"value":"SynopsisDocumentation","title":"First sentence"},{"value":"SingleLine","title":"One line"},{"value":"NoDocumentation","title":"Signature only"}]}
]`

// TestVisualPluginSettingsForm renders the production settings form of an installed
// plugin. The real Core validates the manifest and projects the rows; the settings
// documents live in temporary directories, so the page shows their paths.
// Opt in with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualPluginSettingsForm(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the plugin settings form")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest map[string]json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Manifest["settings"] = json.RawMessage(pluginSettingsVisualDeclarations)
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			source := settingsFormSource{store: pluginsettings.New(core.NewClient(), t.TempDir()), manifest: manifest, workspace: t.TempDir()}
			fetch := func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "dev.example.settings", Name: "Go Support", LatestVersion: "1.0.0"}}}}, nil
			}
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source,
				PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
				InstalledPlugins: func() []PluginFacts {
					return []PluginFacts{{ID: "dev.example.settings", Name: "Go Support", Version: "1.0.0", Settings: 5}}
				},
			}), Values{Theme: look.theme, Language: look.language.Code()})
			w.sess.page = pagePlugins
			w.installed.tab = installedSettings
			config := w.config()
			// Tall enough for all five rows, so one picture shows the whole form.
			config.Height = 1000
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the settings form", func() bool {
				if w.pluginSettings.failed != nil && !w.pluginSettings.running {
					t.Fatalf("the settings form failed: %v", w.pluginSettings.failed)
				}
				return w.pluginSettings.loaded
			})
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "plugin-settings-form-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
