package settingswindow

import (
	"context"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/app"
)

// installedFixture is an Installed tab over two plugins: Go, on and with an update in the
// marketplace, and Builder, off. It records what the tab asks the owner to do.
type installedFixture struct {
	enabled     map[string]bool
	toggles     []string
	installs    []string
	uninstalled []string
}

func (f *installedFixture) window() *window {
	facts := []PluginFacts{
		{ID: "dev.example.go", Name: "Go", Vendor: "Example", Version: "1.0.0", Source: PluginSourceMarketplace,
			Permissions:  []string{"languageServer.launch"},
			Capabilities: []PluginCapability{{Kind: CapabilityLanguageServer, ID: "go", Title: "gopls", Commands: []string{"gopls"}}}},
		{ID: "dev.example.builder", Name: "Builder", Vendor: "Example", Version: "0.1.0", Source: PluginSourceDisk,
			Capabilities: []PluginCapability{{Kind: CapabilityBuildSystem, ID: "builder", Title: "Builder", Tasks: 2}}},
	}
	index := core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{
		ID: "dev.example.go", Name: "Go", LatestVersion: "2.0.0",
		Availability: core.MarketplaceAvailability{Status: "available", Version: "2.0.0"},
		Versions:     []core.MarketplaceVersion{{Version: "2.0.0"}, {Version: "1.0.0"}},
	}}}
	return newWindow(NewController(Options{
		Language: func() i18n.Language { return i18n.English },
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: index}, nil
		},
		InstalledPlugins: func() []PluginFacts { return facts },
		PluginState: func(id string) PluginState {
			for _, fact := range facts {
				if fact.ID == id {
					return PluginState{Installed: true, Version: fact.Version, Enabled: f.enabled[id]}
				}
			}
			return PluginState{}
		},
		SetPluginEnabled: func(id string, enabled bool) {
			f.toggles = append(f.toggles, id)
			f.enabled[id] = enabled
		},
		InstallPlugin:   func(plugin core.MarketplacePlugin) { f.installs = append(f.installs, plugin.ID) },
		UninstallPlugin: func(id string) { f.uninstalled = append(f.uninstalled, id) },
	}), Values{})
}

func TestInstalledTabGroupsPluginsAndActsOnTheChosenOne(t *testing.T) {
	f := &installedFixture{enabled: map[string]bool{"dev.example.go": true}}
	w := f.window()
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.pump()
	if w.pluginTab != pluginTabInstalled {
		t.Fatalf("plugin page opened on tab %d", w.pluginTab)
	}
	if !d.text(words("native.enabled.variant2")) || !d.text(words("native.disabled.variant2")) {
		t.Fatal("the list does not group enabled and disabled plugins")
	}
	if w.installed.selected != "dev.example.go" {
		t.Fatalf("first selection = %q", w.installed.selected)
	}
	summary := i18n.SharedFormat(i18n.English, "native.installedLldOfLldEnabled", map[string]string{"arg1": "1", "arg2": "2"})
	if !d.text(summary) {
		t.Fatal("the summary does not count the enabled plugins")
	}
	// The marketplace offers 2.0.0 over the installed 1.0.0, so the header offers the update.
	update := i18n.SharedFormat(i18n.English, "native.updateTo.variant2", map[string]string{"arg1": "2.0.0"})
	d.click(update)
	if len(f.installs) != 1 || f.installs[0] != "dev.example.go" {
		t.Fatalf("update installed %v", f.installs)
	}
	d.click(words("native.disable"))
	if len(f.toggles) != 1 || f.enabled["dev.example.go"] {
		t.Fatalf("disable toggled %v", f.toggles)
	}
	d.pump()

	// The build chip keeps only the plugin that provides a build system.
	d.click(words("native.build"))
	d.pump()
	if len(w.installed.rows) != 2 || w.installed.rows[1].id != "dev.example.builder" {
		t.Fatalf("build filter rows = %+v", w.installed.rows)
	}
	if w.installed.selected != "dev.example.builder" {
		t.Fatalf("filtered selection = %q", w.installed.selected)
	}

	// Removing asks first; Cancel removes nothing and the destructive button removes it.
	d.click(words("desktop.marketplace.uninstall"))
	d.pump()
	if !w.installed.uninstallOpen || w.installed.uninstallID != "dev.example.builder" {
		t.Fatal("uninstall did not ask for confirmation")
	}
	d.click(words("ui.cancel"))
	d.pump()
	if w.installed.uninstallOpen || len(f.uninstalled) != 0 {
		t.Fatalf("cancel removed %v", f.uninstalled)
	}
	d.click(words("desktop.marketplace.uninstall"))
	d.pump()
	hits := d.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hits[i].Label == words("desktop.marketplace.uninstall") && !hits[i].IsLabel {
			d.clickHit(hits[i])
			break
		}
	}
	d.pump()
	if len(f.uninstalled) != 1 || f.uninstalled[0] != "dev.example.builder" {
		t.Fatalf("confirmed uninstall removed %v", f.uninstalled)
	}
}

func TestInstalledTabSlashPicksAFilter(t *testing.T) {
	f := &installedFixture{enabled: map[string]bool{"dev.example.go": true}}
	w := f.window()
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.click(i18n.Shared(i18n.English, "native.typeToSeeOptions"))
	d.typeText("/dis")
	d.pump()
	d.click(i18n.Shared(i18n.English, "native.disabled.variant2"))
	d.pump()
	if w.installed.filter != installedDisabled || w.installed.query != "" {
		t.Fatalf("slash picked filter %d with query %q", w.installed.filter, w.installed.query)
	}
	for _, row := range w.installed.rows {
		if row.heading == "" && row.id != "dev.example.builder" {
			t.Fatalf("disabled filter lists %q", row.id)
		}
	}
}

func TestInstalledTabShowsPermissionsAndVersions(t *testing.T) {
	f := &installedFixture{enabled: map[string]bool{"dev.example.go": true}}
	w := f.window()
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.click(i18n.Shared(i18n.English, "native.permissionsPrograms"))
	d.pump()
	if !d.text(i18n.Shared(i18n.English, "native.startALanguageServerWhenYouOpenFilesOfItsLanguage")) || !d.text("languageServer.launch") {
		t.Fatal("permissions tab does not describe the approved permission")
	}
	d.click(i18n.Shared(i18n.English, "native.versionsSource"))
	d.pump()
	if !d.text(i18n.Shared(i18n.English, "native.currentVersion")) || !d.text("dev.example.go") {
		t.Fatal("versions tab does not show the version and the ID")
	}
}

func TestRepositoriesDialogAddsAndRemovesAnIndex(t *testing.T) {
	var saved [][]string
	w := newWindow(NewController(Options{
		Language: func() i18n.Language { return i18n.English },
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
		FetchMarketplaceSource: func(context.Context, string) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
		SetMarketplaceSources: func(urls []string) { saved = append(saved, urls) },
	}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	d.click(words("desktop.pluginSettings.title"))
	d.pump()
	d.click(words("native.managePluginRepositories"))
	d.pump()
	if !w.repositoriesOpen {
		t.Fatal("the gear menu did not open the repositories dialog")
	}
	if hit, ok := d.find(words("ai.add")); !ok || !hit.Disabled {
		t.Fatal("Add is enabled with an empty address")
	}
	d.click(words("native.pluginRepositories"))
	d.typeText("https://example.com/index.json")
	d.pump()
	d.click(words("ai.add"))
	d.pump()
	if len(saved) != 1 || len(saved[0]) != 1 || saved[0][0] != "https://example.com/index.json" {
		t.Fatalf("add saved %v", saved)
	}
	d.click(words("ui.remove"))
	d.pump()
	if len(saved) != 2 || len(saved[1]) != 0 {
		t.Fatalf("remove saved %v", saved)
	}
	d.click(words("ui.done"))
	d.pump()
	if w.repositoriesOpen {
		t.Fatal("Done did not close the dialog")
	}
}
