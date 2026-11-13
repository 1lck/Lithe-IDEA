//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualSettings renders the production Page with isolated, offline facts.
// Opt in with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
// LITHE_VISUAL_LANGUAGE optionally selects another supported UI language.
func TestVisualSettings(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the production settings pages")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	language := i18n.Chinese
	if code := os.Getenv("LITHE_VISUAL_LANGUAGE"); code != "" {
		var ok bool
		language, ok = i18n.Parse(code)
		if !ok {
			t.Fatalf("unsupported visual capture language %q", code)
		}
	}
	pages := []struct {
		id   string
		page pageID
	}{
		{"20-settings-general", pageGeneral}, {"22-settings-editor", pageEditor},
		{"23-settings-keymap", pageKeymap}, {"24-settings-network", pageNetwork},
		{"25-settings-process", pageProcessTermination}, {"26-settings-git", pageVersionControl},
		{"27-settings-terminal", pageTerminal}, {"28-plugins-installed", pagePlugins},
		{"29-marketplace-empty", pagePlugins}, {"31-settings-updates", pageUpdates},
		{"33-settings-toolchains", pageBuild}, {"fonts", pageFonts},
		{"21-settings-language-popup", pageGeneral}, {"30-settings-history", pageGeneral}, {"35-settings-search", pageEditor},
		{"m35-editor-tab-layout", pageEditor}, {"m25-project-open-mode", pageGeneral}, {"m29-editor-font-menu", pageFonts}, {"m38-plugin-management-menu", pagePlugins},
		{"m39-proxy-mode-menu", pageNetwork}, {"m40-process-run-policy", pageProcessTermination},
		{"m41-process-terminal-policy", pageProcessTermination}, {"m43-process-orphan-policy", pageProcessTermination},
	}
	for _, theme := range []string{"dark", "light"} {
		for _, scenario := range pages {
			t.Run(scenario.id+"-"+theme, func(t *testing.T) {
				opts := Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, Version: "0.1.0",
					InstalledPlugins: func() []PluginFacts {
						return []PluginFacts{
							{ID: "dev.lithe.editor-shortcut-import", Name: "Editor Shortcut Import", Vendor: "Lithe", Version: "1.0.0", Source: PluginSourceMarketplace},
							{ID: "dev.lithe.java", Name: "Java Support", Vendor: "Lithe", Version: "1.0.0", Source: PluginSourceMarketplace},
						}
					},
					PluginState: func(string) PluginState { return PluginState{Installed: true, Enabled: true, Version: "1.0.0"} }, SystemDark: func() bool { return theme == "dark" },
					SetNetwork: func(NetworkSettings, *string) {}, SetLocalHistory: func(LocalHistorySettings) {},
					StopTime: func() (StopTime, bool) { return StopTime{Default: 5, Min: 1, Max: 30}, true }, SweepsLeftovers: true,
					TerminalShells: func() ([]localshell.Choice, string) {
						return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}, {Name: "bash", Path: "/bin/bash"}}, "/bin/zsh"
					},
					MonospaceFamilies: func() []string { return []string{"JetBrains Mono", "Menlo"} },
					Marketplace:       func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
					UpdateStatus:      func() UpdateStatus { return UpdateStatus{Configured: true} },
					Toolchains:        &fakeToolchainLoader{snapshot: fixtureSnapshot()},
				}
				w := newWindow(NewController(opts), Values{Theme: theme, Language: language.Code(), TerminalScrollback: 2000})
				w.sess.page = scenario.page
				if scenario.id == "29-marketplace-empty" {
					w.pluginTab = pluginTabMarketplace
				}
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				switch scenario.page {
				case pageTerminal:
					d.until("shell choices", func() bool { return w.terminal.loaded })
				case pageBuild:
					d.until("toolchain facts", func() bool { return w.toolchains.loaded })
				case pagePlugins:
					d.until("offline index", func() bool { return w.market.status == marketReady })
				case pageFonts:
					d.until("font families", func() bool { return w.fonts.loaded })
				}
				text := func(key string) string { return i18n.Shared(language, key) }
				switch scenario.id {
				case "m35-editor-tab-layout":
					d.click(w.text.Settings.TabsShowIn)
				case "21-settings-language-popup":
					d.click(w.text.Settings.Language)
				case "30-settings-history":
					if err := d.driver.Scroll(gfx.ScrollEvent{X: 700, Y: 500, DeltaY: 500, Viewport: gfx.Size{Width: 900, Height: 700}}); err != nil {
						t.Fatal(err)
					}
				case "35-settings-search":
					query := "编辑器"
					if language == i18n.English {
						query = "Editor"
					}
					w.searchField.SetText(query)
					d.pump()
				case "m25-project-open-mode":
					d.click(text("desktop.settings.projectOpen"))
				case "m29-editor-font-menu":
					d.click(text("settings.editor.fontFamily"))
					d.key(gfx.KeyDown)
				case "m38-plugin-management-menu":
					d.click(text("desktop.pluginSettings.title"))
				case "m39-proxy-mode-menu":
					d.click(text("desktop.settings.network.mode"))
				case "m40-process-run-policy":
					d.click(text("desktop.settings.processTermination.runServices"))
				case "m41-process-terminal-policy":
					d.click(text("desktop.settings.processTermination.onQuit"))
				case "m43-process-orphan-policy":
					d.click(text("desktop.settings.processTermination.leftoverTerminals"))
				}
				if err := session.Screenshot(filepath.Join(out, scenario.id+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
