package settingswindow

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
		InstallPlugin: func(plugin core.MarketplacePlugin, feedback PluginInstallFeedback) {
			f.installs = append(f.installs, plugin.ID)
			feedback.Finish(false)
		},
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
	d.click(words("native.download"))
	d.click(words("ui.done"))
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

// TestInstalledListClickChoosesTheRowUnderThePointer clicks every row of a list whose plugin
// IDs all have an FNV-32a hash of 2^31 or more. Viva numbers a row's identity only below 2^31
// and gives every key past that the same zero name, so when the keys were those hashes a click
// on any row chose the last plugin.
func TestInstalledListClickChoosesTheRowUnderThePointer(t *testing.T) {
	ids := []string{"dev.lithe.test.first", "dev.lithe.test.second", "dev.lithe.test.third"}
	names := []string{"First Fixture", "Second Fixture", "Third Fixture"}
	facts := make([]PluginFacts, len(ids))
	for i := range ids {
		facts[i] = PluginFacts{ID: ids[i], Name: names[i], Version: "1.0.0", Source: PluginSourceDisk}
	}
	w := newWindow(NewController(Options{
		Language: func() i18n.Language { return i18n.English },
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
		InstalledPlugins: func() []PluginFacts { return facts },
		PluginState: func(id string) PluginState {
			return PluginState{Installed: true, Version: "1.0.0", Enabled: id != ids[2]}
		},
	}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.pump()
	row := func(name string) gfx.Hit {
		for _, hit := range d.driver.Snapshot().Hits {
			if hit.Label == name && hit.Role == gfx.RoleOption {
				return hit
			}
		}
		t.Fatalf("no row %q", name)
		return gfx.Hit{}
	}
	// The third plugin is off, so it sits under the second heading. The list starts on the
	// first row; the clicks go in an order that moves the choice every time.
	for _, i := range []int{1, 2, 0, 1, 0} {
		d.clickHit(row(names[i]))
		d.pump()
		if w.installed.selected != ids[i] {
			t.Fatalf("clicking %q chose %q", names[i], w.installed.selected)
		}
	}
	seen := map[gfx.ID]int{}
	for i := range w.installed.rows {
		id := w.installed.list.RowID(i)
		if previous, ok := seen[id]; ok {
			t.Fatalf("rows %d and %d share the identity %v", previous, i, id)
		}
		seen[id] = i
	}
}

func TestInstalledTabOmitsReinstallForCurrentVersion(t *testing.T) {
	w := (&installedFixture{enabled: map[string]bool{"dev.example.go": true}}).window()
	w.sess.page = pagePlugins
	// The installed and available releases match. Seed the index before the
	// first frame so the test does not wait for a marketplace request.
	w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{
		ID: "dev.example.go", Name: "Go", LatestVersion: "1.0.0",
		Availability: core.MarketplaceAvailability{Status: "available", Version: "1.0.0"},
		Versions:     []core.MarketplaceVersion{{Version: "1.0.0"}},
	}}}}, nil)
	d := openWindow(t, w)
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	d.hit(words("native.disable"))
	d.hit(words("desktop.marketplace.uninstall"))
	if d.has("Reinstall") {
		t.Fatal("the installed tab offers to reinstall the same version")
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

// detailFixture is the detail of one marketplace plugin whose listing names its repository,
// with every field of the Versions & Source and the Permissions & Programs tabs filled in.
// It opens on the Versions & Source tab.
func detailFixture(language i18n.Language) (*window, PluginFacts, string) {
	const repository = "https://github.com/example/versions-fixture"
	fact := PluginFacts{
		ID: "dev.lithe.test.versions", Name: "Versions Fixture", Vendor: "Test", Version: "1.2.3",
		Source: PluginSourceMarketplace, Path: "/plugins/dev.lithe.test.versions/1.2.3",
		ArchiveSHA256: strings.Repeat("a1", 32), ContentDigest: strings.Repeat("c3", 32),
		Permissions: []string{"backend.launch", "commands.install", "languageServer.launch", "process.build", "ui.contribute"},
		Programs: []string{
			`{"kind":"buildSystem","buildSystemID":"fixture","invocation":{"executables":[{"kind":"command","command":"fixture"}]},"tasks":[{"id":"build","arguments":["build","${optionArguments}"]},{"id":"check","arguments":["check","./..."]}]}`,
			`{"kind":"commandInstaller","installer":"fixture-debugger","commands":["fixture-debugger"],"tool":"fixture","minimumVersion":"1.0","arguments":["install","example.com/fixture-debugger@latest"]}`,
			`{"kind":"packagedLanguageServer","path":"bin/fixture-ls","arguments":["serve"],"validationArguments":["--version"],"languageID":"fixture"}`,
		},
	}
	index := core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{
		ID: fact.ID, Name: fact.Name, LatestVersion: fact.Version, Repository: repository,
		Availability: core.MarketplaceAvailability{Status: "available", Version: fact.Version},
		Versions:     []core.MarketplaceVersion{{Version: fact.Version}},
	}}}
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
		SystemLanguage: language,
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: index}, nil
		},
		InstalledPlugins: func() []PluginFacts { return []PluginFacts{fact} },
		PluginState: func(string) PluginState {
			return PluginState{Installed: true, Version: fact.Version, Enabled: true}
		},
		OpenURL: func(string) {},
	}), Values{Language: language.Code()})
	w.sess.page = pagePlugins
	w.installed.tab = installedVersions
	return w, fact, repositoryName(repository)
}

// TestInstalledVersionsLinesUpItsValues covers the grid of the Versions & Source tab: every
// value, the repository link's words included, starts at one left edge, the lines keep one
// spacing, and the note on when the content digest is checked is the ⓘ's tip beside the
// digest, not a line under it.
func TestInstalledVersionsLinesUpItsValues(t *testing.T) {
	w, fact, repository := detailFixture(i18n.English)
	// Wide enough that no value wraps, so every line of the grid is one line of text.
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1400, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.pump()
	// painted is where value was last painted: the detail paints after the plugin list,
	// whose filter chips share some of its words.
	painted := func(value string) gfx.Rect {
		t.Helper()
		texts := d.driver.Snapshot().Texts
		for i := len(texts) - 1; i >= 0; i-- {
			if texts[i].Value == value {
				return texts[i].Bounds
			}
		}
		t.Fatalf("%q is not painted", value)
		return gfx.Rect{}
	}
	edge := painted(fact.Version).X
	for _, value := range []string{repository, fact.Path, fact.ArchiveSHA256, fact.ContentDigest, fact.ID} {
		if x := painted(value).X; x < edge-0.5 || x > edge+0.5 {
			t.Errorf("%q starts at x=%.1f, the values start at x=%.1f", value, x, edge)
		}
	}
	labels := []string{"native.currentVersion", "native.previousVersion", "native.updates", "native.sourceRepository",
		"native.localPackage", "native.archiveSHA256", "native.contentSHA256", "native.pluginID"}
	var tops []float32
	for _, key := range labels {
		tops = append(tops, painted(i18n.Shared(i18n.English, key)).Y)
	}
	step := tops[1] - tops[0]
	for i := 2; i < len(tops); i++ {
		if gap := tops[i] - tops[i-1]; gap < step-0.5 || gap > step+0.5 {
			t.Errorf("%s is %.1f below the line above it, the grid's step is %.1f", labels[i], gap, step)
		}
	}
	help := i18n.Shared(i18n.English, "native.checkedAgainEveryTimeLitheLoadsThePlugin")
	if d.showsHelp(help) {
		t.Fatal("the note on the content digest is permanently visible")
	}
	trigger := d.hintHit(help)
	digest := painted(fact.ContentDigest)
	if trigger.Bounds.X < digest.X+digest.Width || trigger.Bounds.Y > digest.Y+digest.Height || trigger.Bounds.Y+trigger.Bounds.Height < digest.Y {
		t.Fatalf("the ⓘ at %+v does not follow the digest at %+v", trigger.Bounds, digest)
	}
}

// TestInstalledPermissionsKeepsEachEntryToOneLine covers the Permissions & Programs tab: a
// permission's description and its name in the contract share one line, a program is one
// line that names it until it is opened to its full declaration, the copy button beside it
// copies that declaration, and the note on settings is the tip of the ⓘ beside the heading,
// not a paragraph under the list.
func TestInstalledPermissionsKeepsEachEntryToOneLine(t *testing.T) {
	saved := copyText
	t.Cleanup(func() { copyText = saved })
	var copied []string
	copyText = func(text string) error {
		copied = append(copied, text)
		return nil
	}
	w, fact, _ := detailFixture(i18n.English)
	w.installed.tab = installedPermissions
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1400, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.pump()
	painted := func(value string) gfx.Rect {
		t.Helper()
		texts := d.driver.Snapshot().Texts
		for i := len(texts) - 1; i >= 0; i-- {
			if texts[i].Value == value {
				return texts[i].Bounds
			}
		}
		t.Fatalf("%q is not painted", value)
		return gfx.Rect{}
	}
	oneLine := func(what string, left, right gfx.Rect) {
		t.Helper()
		if right.X < left.X+left.Width {
			t.Errorf("%s: %+v does not follow %+v", what, right, left)
		}
		if middle, other := left.Y+left.Height/2, right.Y+right.Height/2; middle-other > 2 || other-middle > 2 {
			t.Errorf("%s: %+v and %+v are not on one line", what, left, right)
		}
	}
	for _, permission := range fact.Permissions {
		oneLine(permission, painted(permissionDescription(i18n.English, permission)), painted(permission))
	}
	declared := func() bool {
		for _, text := range d.driver.Snapshot().Texts {
			if strings.Contains(text.Value, `"kind"`) {
				return true
			}
		}
		return false
	}
	if declared() {
		t.Fatal("a program declaration is shown before it is opened")
	}
	oneLine("the build system", painted("buildSystem"), painted("fixture"))
	oneLine("the installer", painted("commandInstaller"), painted("fixture-debugger · fixture · 1.0"))
	// The programs' names start at the left edge of the permissions' descriptions.
	edge := painted(permissionDescription(i18n.English, fact.Permissions[0])).X
	for _, kind := range []string{"buildSystem", "commandInstaller", "packagedLanguageServer"} {
		if x := painted(kind).X; x < edge-0.5 || x > edge+0.5 {
			t.Errorf("%s starts at x=%.1f, the descriptions start at x=%.1f", kind, x, edge)
		}
	}

	help := i18n.Shared(i18n.English, "desktop.marketplace.programsSettingsHelp")
	if d.showsHelp(help) {
		t.Fatal("the note on settings is permanently visible")
	}
	trigger := d.hintHit(help)
	heading := painted(i18n.Shared(i18n.English, "native.programsItCanRun"))
	oneLine("the programs heading", heading, trigger.Bounds)

	d.click("buildSystem fixture")
	d.pump()
	if !d.wrapped(`"buildSystemID": "fixture",`) {
		t.Fatal("the opened program does not show its declaration")
	}
	d.click("buildSystem fixture")
	d.pump()
	if declared() {
		t.Fatal("the program does not close again")
	}

	var copies []gfx.Hit
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == i18n.Shared(i18n.English, "native.copyJSON") && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			copies = append(copies, hit)
		}
	}
	if len(copies) != len(fact.Programs) {
		t.Fatalf("%d copy buttons for %d programs", len(copies), len(fact.Programs))
	}
	d.clickHit(copies[1])
	d.pump()
	if want := programDeclaration(fact.Programs[1]); len(copied) != 1 || copied[0] != want {
		t.Fatalf("copied %q, want %q", copied, want)
	}
}

func TestProgramSummaryNamesTheDeclaration(t *testing.T) {
	for _, tc := range []struct{ program, kind, detail string }{
		{`{"kind":"buildSystem","buildSystemID":"go","tasks":[{"id":"build"}]}`, "buildSystem", "go"},
		{`{"kind":"commandInstaller","installer":"dlv","commands":["dlv"],"tool":"go"}`, "commandInstaller", "dlv · go"},
		{`{"path":"bin/server","kind":"packagedLanguageServer","languageID":"go"}`, "packagedLanguageServer", "bin/server · go"},
		{`{"kind":"run"}`, "run", ""},
		{`{"languageID":"go"}`, "", ""},
		{`["kind","run"]`, "", ""},
		{`not json`, "", ""},
	} {
		if kind, detail := programSummary(tc.program); kind != tc.kind || detail != tc.detail {
			t.Errorf("programSummary(%s) = %q, %q; want %q, %q", tc.program, kind, detail, tc.kind, tc.detail)
		}
	}
	if got := programDeclaration(`{"kind":"run","arguments":["a"]}`); got != "{\n  \"kind\": \"run\",\n  \"arguments\": [\n    \"a\"\n  ]\n}" {
		t.Errorf("programDeclaration indents to %q", got)
	}
	if got := programDeclaration(`not json`); got != "not json" {
		t.Errorf("programDeclaration changed a declaration that is not JSON to %q", got)
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

// A plugin's Settings tab grows its form to the height under the tab bar, so the settings list
// fills it and shows its last row whole, rather than sitting at a fixed height in the scroll.
func TestInstalledSettingsTabListFillsTheDetail(t *testing.T) {
	const count = 30
	manifest := flagsManifest(t, count)
	facts := []PluginFacts{{ID: "dev.example.settings", Name: "Settings", Vendor: "Example", Version: "1.0.0", Source: PluginSourceDisk, Settings: count}}
	fits := map[int]settingsListFit{}
	for _, height := range settingsListHeights {
		client := core.NewClient()
		source := settingsFormSource{store: pluginsettings.New(client, t.TempDir()), manifest: manifest, workspace: t.TempDir()}
		w := newWindow(NewController(Options{
			Language: func() i18n.Language { return i18n.English },
			Marketplace: func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{}, nil
			},
			InstalledPlugins: func() []PluginFacts { return facts },
			PluginState: func(string) PluginState {
				return PluginState{Installed: true, Version: "1.0.0", Enabled: true}
			},
			PluginSettings: source,
		}), Values{})
		w.sess.page = pagePlugins
		d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, height })
		d.until("the marketplace index", func() bool { return w.market.status == marketReady })
		w.installed.tab = installedSettings
		d.until("the form", func() bool { return w.pluginSettings != nil && w.pluginSettings.loaded && !w.pluginSettings.running })
		w.inv.Invalidate()
		d.pump()
		fits[height] = measureSettingsList(t, d, w, fmt.Sprintf("Flag %02d", count-1))
	}
	checkSettingsListFills(t, fits)
}
