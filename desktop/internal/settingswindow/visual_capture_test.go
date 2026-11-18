//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
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
		{"25-settings-process", pageProcessTermination}, {"26-settings-git", pageVersionControl}, {"26-settings-git-console", pageVersionControl},
		{"27-settings-terminal", pageTerminal}, {"28-plugins-installed", pagePlugins},
		{"29-marketplace-empty", pagePlugins}, {"31-settings-updates", pageUpdates},
		{"33-settings-toolchains", pageBuild}, {"m44-toolchain-directory-menu", pageBuild}, {"m45-toolchain-custom-directory", pageBuild},
		{"m47-toolchain-project-untrusted", pageBuild}, {"m48-toolchain-project-trusted", pageBuild}, {"m49-toolchain-project-trust-help", pageBuild},
		{"m50-toolchain-project-trust-tip", pageBuild},
		{"fonts", pageFonts},
		{"21-settings-language-popup", pageGeneral}, {"30-settings-history", pageGeneral}, {"m46-history-default-rules-help", pageGeneral}, {"35-settings-search", pageEditor},
		{"m35-editor-tab-layout", pageEditor}, {"m25-project-open-mode", pageGeneral}, {"m29-editor-font-menu", pageFonts}, {"m38-plugin-management-menu", pagePlugins},
		{"m39-proxy-mode-menu", pageNetwork}, {"m40-process-run-policy", pageProcessTermination},
		{"m41-process-terminal-policy", pageProcessTermination}, {"m43-process-orphan-policy", pageProcessTermination},
		{"36-settings-about", pageAbout},
	}
	for _, theme := range []string{"dark", "light"} {
		for _, scenario := range pages {
			t.Run(scenario.id+"-"+theme, func(t *testing.T) {
				opts := Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, Version: "0.7.0",
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
					Toolchains:        visualToolchainLoader(scenario.id),
					// Every build can sign in to GitHub; no account is connected yet.
					GitHub: &GitHubAccount{Snapshot: func() GitHubState { return GitHubState{Available: true} }},
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
				case "26-settings-git-console":
					if err := d.driver.Scroll(gfx.ScrollEvent{X: 700, Y: 500, DeltaY: 900, Viewport: gfx.Size{Width: 900, Height: 700}}); err != nil {
						t.Fatal(err)
					}
				case "30-settings-history":
					if err := d.driver.Scroll(gfx.ScrollEvent{X: 700, Y: 500, DeltaY: 500, Viewport: gfx.Size{Width: 900, Height: 700}}); err != nil {
						t.Fatal(err)
					}
				case "m46-history-default-rules-help":
					// The ⓘ on the wildcard list's row explains the default rules: the folders
					// hidden from the tree, which deleting a line does not record.
					if err := d.driver.Scroll(gfx.ScrollEvent{X: 700, Y: 500, DeltaY: 500, Viewport: gfx.Size{Width: 900, Height: 700}}); err != nil {
						t.Fatal(err)
					}
					d.pump()
					help := text("desktop.settings.localHistory.wildcardHelp") + " " + text("desktop.settings.localHistory.builtInsHelp")
					info := d.hintHit(help).Bounds
					x, y := info.X+info.Width/2, info.Y+info.Height/2
					if err := d.driver.Move(x, y); err != nil {
						t.Fatal(err)
					}
					if err := d.driver.Click(x, y); err != nil {
						t.Fatal(err)
					}
					d.pump()
					if !d.showsHelp(help) {
						t.Fatal("the ⓘ did not pin its help open")
					}
					// The popover fades in; move the frame clock past it.
					if err := session.Advance(time.Second); err != nil {
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
				case "m44-toolchain-directory-menu":
					d.click("Compiler")
				case "m45-toolchain-custom-directory":
					d.click("Compiler")
					d.click(text("desktop.toolchains.custom"))
					d.pump()
				case "m47-toolchain-project-untrusted", "m48-toolchain-project-trusted", "m49-toolchain-project-trust-help", "m50-toolchain-project-trust-tip":
					d.click(text("desktop.toolchains.project"))
					status := text("desktop.toolchains.trustStatusTrusted")
					if scenario.id == "m47-toolchain-project-untrusted" {
						status = text("desktop.toolchains.trustStatusUntrusted")
					}
					// The load result can arrive during painting, before the trust controls appear.
					d.until("the visible project trust status", func() bool { return d.text(status) })
					if scenario.id != "m49-toolchain-project-trust-help" && scenario.id != "m50-toolchain-project-trust-tip" {
						break
					}
					help := text("desktop.toolchains.trustProjectHelp")
					info := d.hintHit(help).Bounds
					x, y := info.X+info.Width/2, info.Y+info.Height/2
					if err := d.driver.Move(x, y); err != nil {
						t.Fatal(err)
					}
					if scenario.id == "m50-toolchain-project-trust-tip" {
						// Resting on the ⓘ without pressing it shows the help in the client's
						// shared hover tip rather than the pinned popover.
						if err := session.Advance(time.Second); err != nil {
							t.Fatal(err)
						}
						if !d.showsHelp(help) {
							t.Fatal("resting on the project trust ⓘ did not show its tip")
						}
						break
					}
					if err := d.driver.Click(x, y); err != nil {
						t.Fatal(err)
					}
					d.pump()
					if !d.showsHelp(help) {
						t.Fatal("the project trust ⓘ did not pin its help open")
					}
					if err := session.Advance(time.Second); err != nil {
						t.Fatal(err)
					}
				}
				if err := session.Screenshot(filepath.Join(out, scenario.id+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func globalVisualToolchains() toolchain.Snapshot {
	snapshot := fixtureSnapshot()
	snapshot.Root = ""
	tool := &snapshot.Tools[0]
	tool.AutomaticHome = "/fixture/compiler"
	tool.CustomHomes = []string{"/fixture/sdk8", "/fixture/sdk21"}
	for index, home := range tool.CustomHomes {
		version := []string{"8.0.1", "21.0.4"}[index]
		tool.Installations = append(tool.Installations, core.ToolchainInstallation{Home: home, Version: version, Provider: "host:manual"})
	}
	tool.Pin = &core.ToolchainPin{Home: "/fixture/sdk21", Provider: "host:default"}
	selected := "/fixture/sdk21"
	tool.Effective = &core.ToolchainSelection{Home: &selected, Executable: selected + "/bin/compiler", Version: "21.0.4", Layer: "global"}
	return snapshot
}

func visualToolchainLoader(scenarioID string) ToolchainLoader {
	global := globalVisualToolchains()
	venvHome := "/fixture/workspace/.venv"
	untrusted := toolchain.Snapshot{
		Root:      "/fixture/workspace",
		Directory: ".",
		Tools: []toolchain.Tool{{
			ID:          "dev.lithe.test.runtime:interp",
			DisplayName: "Synthetic Runtime",
			PluginID:    "dev.lithe.test.runtime",
			Project: []core.ToolchainProjectCandidate{{
				CandidateID: "project-venv",
				ProjectKind: "environment",
				Path:        venvHome + "/bin/interp",
				Home:        venvHome,
				Reason:      "projectCodeRequiresAction",
			}},
			Installations: []core.ToolchainInstallation{{
				Home: "/fixture/runtimes/3.11", Version: "3.11.9", Provider: "host:system",
			}},
		}},
	}
	venvVersion := "3.12.4"
	trusted := toolchain.Snapshot{
		Root:               "/fixture/workspace",
		Directory:          ".",
		ProjectCodeAllowed: true,
		Tools: []toolchain.Tool{{
			ID:            "dev.lithe.test.runtime:interp",
			DisplayName:   "Synthetic Runtime",
			PluginID:      "dev.lithe.test.runtime",
			AutomaticHome: venvHome,
			Effective: &core.ToolchainSelection{
				Home:        &venvHome,
				Executable:  venvHome + "/bin/interp",
				Version:     venvVersion,
				Provider:    "host:project",
				Layer:       "project",
				ProjectCode: true,
			},
			Project: []core.ToolchainProjectCandidate{{
				CandidateID: "project-venv",
				ProjectKind: "environment",
				Path:        venvHome + "/bin/interp",
				Home:        venvHome,
				Executable:  venvHome + "/bin/interp",
				Version:     &venvVersion,
			}},
			Installations: []core.ToolchainInstallation{{
				Home: "/fixture/runtimes/3.11", Version: "3.11.9", Provider: "host:system",
			}},
		}},
	}
	switch scenarioID {
	case "m47-toolchain-project-untrusted":
		return &trustToolchainLoader{globalSnapshot: global, untrusted: untrusted, trustedSnapshot: trusted}
	case "m48-toolchain-project-trusted", "m49-toolchain-project-trust-help", "m50-toolchain-project-trust-tip":
		return &trustToolchainLoader{globalSnapshot: global, untrusted: untrusted, trustedSnapshot: trusted, trusted: true}
	default:
		return &scopedToolchainLoader{fakeToolchainLoader{snapshot: global}}
	}
}
