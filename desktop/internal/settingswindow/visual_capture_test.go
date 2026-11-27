//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
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
		{"25-settings-process", pageProcessTermination}, {"26-settings-version-control", pageVersionControl}, {"26-settings-git", pageGit}, {"26-settings-git-console", pageGit},
		{"27-settings-terminal", pageTerminal}, {"28-plugins-installed", pagePlugins},
		{"29-marketplace-empty", pagePlugins}, {"29-marketplace-recommendations", pagePlugins},
		{"32-settings-build", pageBuild}, {"32-settings-build-kind", pageBuild}, {"34-settings-debuggers", pageDebuggers},
		{"34-settings-debuggers-pattern-hover", pageDebuggers}, {"34-settings-debuggers-feature-hover", pageDebuggers},
		{"33-settings-toolchains", pageToolchains}, {"m44-toolchain-directory-menu", pageToolchains}, {"m45-toolchain-custom-directory", pageToolchains},
		{"m47-toolchain-project-untrusted", pageToolchains}, {"m48-toolchain-project-trusted", pageToolchains}, {"m49-toolchain-project-trust-click", pageToolchains},
		{"m50-toolchain-project-trust-tip", pageToolchains},
		{"m51-toolchain-provider-installation", pageToolchains},
		{"fonts", pageFonts},
		{"21-settings-language-popup", pageGeneral}, {"30-settings-history", pageGeneral}, {"m46-history-default-rules-help", pageGeneral}, {"35-settings-search", pageEditor},
		{"m35-editor-tab-layout", pageEditor}, {"m25-project-open-mode", pageGeneral}, {"m29-editor-font-menu", pageFonts}, {"m38-plugin-management-menu", pagePlugins}, {"m42-plugin-auto-update-on", pagePlugins},
		{"m39-proxy-mode-menu", pageNetwork}, {"m40-process-run-policy", pageProcessTermination},
		{"m41-process-terminal-policy", pageProcessTermination}, {"m43-process-orphan-policy", pageProcessTermination},
		{"36-settings-about", pageAbout}, {"36-settings-about-projects", pageAbout},
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
					StopTime: func() (StopTime, bool) { return StopTime{Default: 5, Min: 1, Max: 30}, true },
					TerminalShells: func() ([]localshell.Choice, string) {
						return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}, {Name: "bash", Path: "/bin/bash"}}, "/bin/zsh"
					},
					MonospaceFamilies: func() []string { return []string{"JetBrains Mono", "Menlo"} },
					Marketplace:       func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
					UpdateStatus: func() UpdateStatus {
						return UpdateStatus{Configured: true, Installed: buildinfo.ChannelStable, Channel: buildinfo.ChannelStable}
					},
					Toolchains: visualToolchainLoader(scenario.id),
					// Every build can sign in to GitHub; no account is connected yet.
					GitHub: &GitHubAccount{Snapshot: func() GitHubState { return GitHubState{Available: true} }},
					// Two installed debuggers take stepping filters; one keeps the user's own.
					SteppingAdapters: func(context.Context) ([]SteppingAdapter, error) {
						return []SteppingAdapter{
							{ID: "fixture-jvm", Name: "Fixture JVM Debugger", PluginID: "dev.example.jvm", PluginName: "Fixture JVM", Defaults: core.DebugSteppingFilters{ClassNameFilters: []string{"java.*", "javax.*", "sun.*"}, SkipSynthetics: true, SkipStaticInitializers: true}},
							{ID: "fixture-native", Name: "Fixture Native Debugger", PluginID: "dev.example.native", PluginName: "Fixture Native", Defaults: core.DebugSteppingFilters{ClassNameFilters: []string{"std::*"}}},
						}, nil
					},
					NormalizeSteppingFilters: func(_ context.Context, _ string, filters core.DebugSteppingFilters) (core.DebugSteppingFilters, error) {
						return filters, nil
					},
					SetSteppingFilters: func(string, *core.DebugSteppingFilters) {},
				}
				if scenario.id == "20-settings-general" {
					opts.WorkbenchBackground = func(i18n.Language) WorkbenchBackground {
						return WorkbenchBackground{Set: true, Status: "fixture.png", Strength: "subtle",
							Image: gfx.Bitmap{Width: 1, Height: 1, Stride: 4, ID: 1 << 62, Pix: []byte{72, 116, 158, 255}}}
					}
				}
				opts.SetAutoUpdatePlugins = func(bool) {}
				values := Values{Theme: theme, Language: language.Code(), TerminalScrollback: 2000, AutoUpdatePlugins: scenario.id == "m42-plugin-auto-update-on"}
				if scenario.id == "29-marketplace-recommendations" {
					query := ""
					values.MarketplaceQuery = &query
					opts.Marketplace = func(context.Context) (marketplace.Snapshot, error) {
						return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{
							{ID: "dev.lithe.test.demo-build", Name: "Demo Build", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}},
							{ID: "dev.lithe.test.demo-language", Name: "Demo Language", Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"}},
						}}}, nil
					}
					opts.PluginState = nil
				}
				if scenario.page == pageBuild || scenario.page == pageDebuggers {
					values.SteppingFilters = map[string]core.DebugSteppingFilters{"fixture-jvm": {ClassNameFilters: []string{"java.*", "javax.*", "sun.*", "com.example.generated.*"}, SkipSynthetics: true, SkipStaticInitializers: true}}
				}
				if scenario.page == pageBuild {
					// Eight plugins each bring a build system page, which the kind's one row and
					// page list.
					contributions := buildPageContributions(t, 8)
					client := core.NewClient()
					opts.PluginSettings = newBuildFormSource(t, client, contributions)
					opts.SettingsNavigation = client.SettingsNavigation
					opts.SettingsPages = func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
						return client.SettingsPages(ctx, contributions, "")
					}
				}
				w := newWindow(NewController(opts), values)
				w.sess.page = scenario.page
				if scenario.id == "29-marketplace-recommendations" && (w.pluginTab != pluginTabMarketplace || w.marketQuery != "") {
					t.Fatal("recommendations must open the unfiltered Marketplace")
				}
				if scenario.page == pageBuild || parents[scenario.page] == pageBuild {
					// As the Build page opens its pages: with the group open in the sidebar.
					w.sess.open[pageBuild] = true
				}
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
				case pageToolchains:
					d.until("toolchain facts", func() bool { return w.toolchains.current().loaded })
				case pageBuild:
					d.until("the build page's facts", func() bool {
						return w.toolchains.current().loaded && w.toolchains.view.ready && w.stepping.loaded && w.dynamic.loaded
					})
				case pageDebuggers:
					d.until("the debuggers", func() bool { return w.stepping.loaded })
				case pagePlugins:
					d.until("offline index", func() bool { return w.market.status == marketReady })
				case pageFonts:
					d.until("font families", func() bool { return w.fonts.loaded })
				}
				text := func(key string) string { return i18n.Shared(language, key) }
				switch scenario.id {
				case "34-settings-debuggers-pattern-hover", "34-settings-debuggers-feature-hover":
					d.pump()
					label := "java.*"
					if scenario.id == "34-settings-debuggers-feature-hover" {
						label = text("desktop.settings.stepping.skipSynthetics")
					}
					found := false
					for _, text := range d.driver.Snapshot().Labels {
						if text.Value == label {
							if err := d.driver.Move(text.Bounds.X+4, text.Bounds.Y+text.Bounds.Height/2); err != nil {
								t.Fatal(err)
							}
							found = true
							break
						}
					}
					if !found {
						t.Fatalf("no hover target for %q", label)
					}
				case "m35-editor-tab-layout":
					d.click(w.text.Settings.TabsShowIn)
				case "21-settings-language-popup":
					d.click(w.text.Settings.Language)
				case "26-settings-git-console":
					if err := d.driver.Scroll(gfx.ScrollEvent{X: 700, Y: 500, DeltaY: 900, Viewport: gfx.Size{Width: 900, Height: 700}}); err != nil {
						t.Fatal(err)
					}
				case "36-settings-about-projects":
					// The project links sit under the update card, past the first screen.
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
					// Resting on the ⓘ shows its tip; move the frame clock past the hover delay.
					if err := session.Advance(time.Second); err != nil {
						t.Fatal(err)
					}
					if !d.showsHelp(help) {
						t.Fatal("resting on the ⓘ did not show its help")
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
				case "m38-plugin-management-menu", "m42-plugin-auto-update-on":
					d.click(text("desktop.pluginSettings.title"))
				case "m39-proxy-mode-menu":
					d.click(text("desktop.settings.network.mode"))
				case "m40-process-run-policy":
					d.click(text("desktop.settings.processTermination.runServices"))
				case "m41-process-terminal-policy":
					d.click(text("desktop.settings.processTermination.onQuit"))
				case "m43-process-orphan-policy":
					d.click(text("desktop.settings.processTermination.leftoverTerminals"))
				case "32-settings-build-kind":
					w.openKind("buildSystem")
					d.until("the first page's settings", func() bool {
						return w.shownKind() == "buildSystem" && w.pluginSettings.loaded && w.pluginSettings.id == w.contributorID
					})
					d.pump()
				case "m44-toolchain-directory-menu":
					d.click("Compiler")
				case "m45-toolchain-custom-directory":
					d.click(text("desktop.buildSettings.addDirectory"))
					d.pump()
				case "m51-toolchain-provider-installation":
					d.until("the provider installation", func() bool { return d.has("/fixture/provider/compiler") })
				case "m47-toolchain-project-untrusted", "m48-toolchain-project-trusted", "m49-toolchain-project-trust-click", "m50-toolchain-project-trust-tip":
					d.until("the project scope", func() bool { return w.toolchains.projectName() != "" })
					d.pump()
					d.click(i18n.SharedFormat(language, "desktop.buildSettings.scopeProjectNamed", map[string]string{"project": "workspace"}))
					status := text("desktop.toolchains.trustStatusTrusted")
					if scenario.id != "m48-toolchain-project-trusted" {
						status = text("desktop.buildSettings.trustProject")
					}
					// The load result can arrive during painting, before the trust controls appear.
					d.until("the visible project trust status", func() bool { return d.has(status) })
					if scenario.id != "m49-toolchain-project-trust-click" && scenario.id != "m50-toolchain-project-trust-tip" {
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
						// shared hover tip.
						if err := session.Advance(time.Second); err != nil {
							t.Fatal(err)
						}
						if !d.showsHelp(help) {
							t.Fatal("resting on the project trust ⓘ did not show its tip")
						}
						break
					}
					// Pressing the ⓘ hides its tip and opens no card in its place.
					if err := d.driver.Click(x, y); err != nil {
						t.Fatal(err)
					}
					d.pump()
					if err := session.Advance(time.Second); err != nil {
						t.Fatal(err)
					}
					if d.showsHelp(help) {
						t.Fatal("pressing the project trust ⓘ left its help on screen")
					}
				}
				if err := session.Screenshot(filepath.Join(out, scenario.id+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestVisualToolchainEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(theme+"-"+language.Code(), func(t *testing.T) {
				snapshot := fixtureSnapshot()
				home := "/toolchains/" + strings.Repeat("long-installation-directory/", 4) + "compiler"
				tool := &snapshot.Tools[0]
				tool.AutomaticHome, tool.Automatic.Home, tool.Installations[0].Home = home, &home, home
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					Toolchains: &fakeToolchainLoader{snapshot: snapshot},
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.page = pageToolchains
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.until("the toolchain list", func() bool { return w.toolchains.current().loaded && w.toolchains.view.ready })
				d.pump()
				shot := func(scene string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "ellipsis-toolchain-"+scene+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				}
				shot("before-hover")
				found := false
				for _, label := range d.driver.Snapshot().Labels {
					if strings.HasPrefix(label.Value, "/toolchains/") && strings.HasSuffix(label.Value, "…") {
						if err := d.driver.Move(label.Bounds.X+2, label.Bounds.Y+label.Bounds.Height/2); err != nil {
							t.Fatal(err)
						}
						found = true
						break
					}
				}
				if !found {
					t.Fatal("the installation did not show its shortened path")
				}
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				shot("path-hover")
			})
		}
	}
}

// TestVisualSidebarEllipsis captures a page name the sidebar cuts short with its full name shown
// to its right. Only the English sidebar cuts a built-in page name short, so it is captured in
// English alone.
func TestVisualSidebarEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	language := i18n.English
	for _, theme := range []string{"dark", "light"} {
		t.Run(theme+"-"+language.Code(), func(t *testing.T) {
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
			}), Values{Theme: theme, Language: language.Code()})
			session, err := headless.Open(w.config(), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.pump()
			full := titleOf(&w.text.Settings, pageBuild)
			if got, _ := d.restForTip(d.cutSidebarEntry(full), session.Advance); got != full {
				t.Fatalf("sidebar tooltip %q, want %q", got, full)
			}
			if err := session.Screenshot(filepath.Join(out, "ellipsis-settings-sidebar-hover-"+theme+"-"+language.Code()+".png")); err != nil {
				t.Fatal(err)
			}
		})
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
	case "m51-toolchain-provider-installation":
		snapshot := fixtureSnapshot()
		snapshot.Root = ""
		tool := &snapshot.Tools[0]
		const provider = "dev.example:discovery"
		home := "/fixture/provider/compiler"
		tool.PluginName = "Example Toolchain"
		tool.Providers = []string{provider}
		tool.AutomaticHome = home
		tool.Automatic = &core.ToolchainSelection{Home: &home, Executable: home + "/bin/compiler", Version: "2.0.0", Provider: provider, Layer: "global"}
		tool.Effective = tool.Automatic
		tool.Installations = []core.ToolchainInstallation{{Home: home, Version: "2.0.0", Provider: provider}}
		return &scopedToolchainLoader{fakeToolchainLoader{snapshot: snapshot}}
	case "m47-toolchain-project-untrusted", "m49-toolchain-project-trust-click", "m50-toolchain-project-trust-tip":
		return &trustToolchainLoader{globalSnapshot: global, untrusted: untrusted, trustedSnapshot: trusted}
	case "m48-toolchain-project-trusted":
		loader := &trustToolchainLoader{globalSnapshot: global, untrusted: untrusted, trustedSnapshot: trusted}
		loader.trusted.Store(true)
		return loader
	default:
		return &scopedToolchainLoader{fakeToolchainLoader{snapshot: global}}
	}
}
