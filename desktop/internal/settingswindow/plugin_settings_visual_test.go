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
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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
	manifest := pluginSettingsVisualManifest(t)
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

// pluginSettingsVisualManifest is the Core fixture's plugin manifest with the settings above.
func pluginSettingsVisualManifest(t *testing.T) []byte {
	t.Helper()
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
	return manifest
}

// TestVisualPluginSettingsPage renders the language page the plugin above contributes,
// opened from the sidebar: Languages & Frameworks expanded to show it, and Build,
// Execution, Deployment folding the plugin's build page away. Opt in as above.
func TestVisualPluginSettingsPage(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the plugin settings page")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	manifest := pluginSettingsVisualManifest(t)
	client := core.NewClient()
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			source := settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				PluginSettings: source, SettingsNavigation: client.SettingsNavigation,
				SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
					return client.SettingsPages(ctx, []core.SettingsContribution{{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example.settings", Version: "1.0.0"}, Enabled: true}}, "")
				},
			}), Values{Theme: look.theme, Language: look.language.Code()})
			config := w.config()
			config.Height = 760
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the plugin's pages", func() bool { return len(w.dynamic.pages) == 2 })
			for _, page := range w.dynamic.pages {
				if contributedParent(page.Kind) == pageLanguages {
					w.selectSettingsPage(pageLanguages, page.Key)
				}
			}
			d.until("the settings form", func() bool {
				if w.pluginSettings.failed != nil && !w.pluginSettings.running {
					t.Fatalf("the settings form failed: %v", w.pluginSettings.failed)
				}
				return w.pluginSettings.loaded
			})
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "plugin-settings-page-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
			w.ctrl.SetWorkspaceBuildOptions(map[string][]WorkspaceBuildOptions{
				"go": {{InstanceID: "fixture", PluginID: "dev.example.settings", Name: "Go", Root: "tools", Open: func() {}}},
			})
			w.openKind("buildSystem")
			w.inv.Invalidate()
			label := i18n.SharedFormat(look.language, "desktop.buildSettings.workspaceOptionsAt", map[string]string{"name": "Go", "root": "tools"})
			d.until("workspace build options link", func() bool { return d.has(label) && w.pluginSettings.loaded })
			if err := session.Screenshot(filepath.Join(out, "workspace-build-options-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

type visualUnavailableActionSource struct {
	settingsFormSource
	err error
}

func (s visualUnavailableActionSource) Action(context.Context, pluginservice.SettingsEditor, string, bool) (pluginservice.SettingsActionResult, error) {
	return pluginservice.SettingsActionResult{}, s.err
}

func TestVisualPluginSettingsUnavailableAction(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the unavailable plugin settings action")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest map[string]any `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Manifest["settings"] = []any{map[string]any{"id": "languageServerFolder", "type": "directory", "title": "Language server folder", "default": "", "page": map[string]any{"languageID": "fixture"}, "effect": "restart"}}
	fixture.Manifest["settingActions"] = []any{map[string]any{"id": "read", "title": "Read compiler settings", "function": "compiler.read", "page": map[string]any{"languageID": "fixture"}}}
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			source := visualUnavailableActionSource{
				settingsFormSource: settingsFormSource{store: pluginsettings.New(core.NewClient(), t.TempDir()), manifest: manifest, workspace: workspace},
				err:                &pluginbackend.SessionUnavailableError{PluginID: "dev.example.settings", LanguageID: "fixture", Detail: "resolve the fixture launch: executable not found"},
			}
			fetch := func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "dev.example.settings", Name: "Fixture Support", LatestVersion: "1.0.0"}}}}, nil
			}
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				Marketplace: fetch, MarketplaceInstalled: fetch, PluginSettings: source,
				PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} },
				InstalledPlugins: func() []PluginFacts {
					return []PluginFacts{{ID: "dev.example.settings", Name: "Fixture Support", Version: "1.0.0", Settings: 1}}
				},
				PluginRuntime: func(string) PluginRuntimeState {
					return PluginRuntimeState{Failed: true, RestartRequired: true, Version: "1.0.0", Workspace: workspace}
				},
				RestartPlugin: func(string, string, string, string) {},
			}), Values{Theme: look.theme, Language: look.language.Code()})
			w.sess.page = pagePlugins
			w.installed.tab = installedSettings
			config := w.config()
			config.Height = 760
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the plugin form", func() bool { return w.pluginSettings.loaded })
			d.click("Read compiler settings")
			d.until("the action failure", func() bool { return w.pluginSettings.failed != nil && !w.pluginSettings.running })
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "plugin-settings-unavailable-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
