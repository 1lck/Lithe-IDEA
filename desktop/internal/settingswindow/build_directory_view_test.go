package settingswindow

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// buildPageContributions are count enabled plugins, each with two settings on a build system
// page of its own, bs00, bs01 and so on, so the real Core projects count pages of that kind.
func buildPageContributions(t *testing.T, count int) []core.SettingsContribution {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	contributions := make([]core.SettingsContribution, 0, count)
	for index := range count {
		id := fmt.Sprintf("bs%02d", index)
		fixture.Manifest["id"] = "dev.example." + id
		fixture.Manifest["displayName"] = fmt.Sprintf("Builder %02d", index)
		page := map[string]string{"buildSystemID": id}
		fixture.Manifest["settings"] = []any{
			map[string]any{"id": "offline", "type": "boolean", "title": "Work offline", "default": false, "page": page, "section": "Options"},
			map[string]any{"id": "jobs", "type": "integer", "title": "Parallel jobs", "default": 4, "minimum": 1, "maximum": 64, "page": page, "section": "Options"},
		}
		delete(fixture.Manifest, "settingActions")
		manifest, err := json.Marshal(fixture.Manifest)
		if err != nil {
			t.Fatal(err)
		}
		contributions = append(contributions, core.SettingsContribution{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example." + id, Version: "1.0.0"}, Enabled: true})
	}
	return contributions
}

// buildFormSource loads each plugin's settings from its own manifest, kept in a store of the
// test's own.
type buildFormSource struct {
	store     *pluginsettings.Store
	manifests map[string]json.RawMessage
	workspace string
}

// newBuildFormSource is the settings of contributions, kept under t's temporary directories.
func newBuildFormSource(t *testing.T, client *core.Client, contributions []core.SettingsContribution) buildFormSource {
	t.Helper()
	manifests := make(map[string]json.RawMessage, len(contributions))
	for _, contribution := range contributions {
		manifests[contribution.Owner.PluginID] = contribution.Manifest
	}
	return buildFormSource{store: pluginsettings.New(client, t.TempDir()), manifests: manifests, workspace: t.TempDir()}
}

func (s buildFormSource) Load(ctx context.Context, id string, _ i18n.Language) (pluginservice.SettingsEditor, error) {
	snapshot, err := s.store.Load(ctx, s.manifests[id], s.workspace)
	return pluginservice.SettingsEditor{Snapshot: snapshot}, err
}

func (s buildFormSource) Save(ctx context.Context, editor pluginservice.SettingsEditor, scope string, edits []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	return s.store.Save(ctx, editor.Snapshot, scope, edits, nil)
}

// buildPagesWindow is an English settings window whose plugins put count build system pages
// under Build, Execution, Deployment, opened on that page and loaded.
func buildPagesWindow(t *testing.T, count int) (*window, *windowDriver) {
	t.Helper()
	contributions := buildPageContributions(t, count)
	client := core.NewClient()
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, Language: func() i18n.Language { return i18n.English },
		PluginSettings:     newBuildFormSource(t, client, contributions),
		SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, contributions, "")
		},
	}), Values{Theme: "dark"})
	w.sess.page = pageBuild
	d := openWindow(t, w, func(config *app.Config) { config.Height = 900 })
	d.until("the plugin pages", func() bool { return w.dynamic.loaded && len(w.dynamic.pages) == count })
	return w, d
}

func TestBuildSettingsOpensOptionsForTheChosenWorkspaceInstance(t *testing.T) {
	w, d := buildPagesWindow(t, 2)
	opened := ""
	w.ctrl.SetWorkspaceBuildOptions(map[string][]WorkspaceBuildOptions{
		"bs00": {
			{InstanceID: "root", PluginID: "dev.example.bs00", Name: "Builder 00", Open: func() { opened = "root" }},
			{InstanceID: "child", PluginID: "dev.example.bs00", Name: "Builder 00", Root: "subproject", Open: func() { opened = "child" }},
		},
	})
	w.openKind("buildSystem")
	w.inv.Invalidate()
	const child = "Builder 00 workspace options (subproject)"
	d.until("the detected workspace options", func() bool { return d.has(child) })
	d.click(child)
	if opened != "child" {
		t.Fatalf("opened %q, want the nested instance", opened)
	}
	w.ctrl.SetWorkspaceBuildOptions(nil)
	w.inv.Invalidate()
	d.pump()
	if d.has(child) || d.has("Builder 00 workspace options") {
		t.Fatal("closed workspace still offers links to its build instances")
	}
}

// buildRows are the rows below Build, Execution, Deployment: the kinds' rows and any plugin
// page a search lists.
func buildRows(w *window) []row {
	var rows []row
	inside := false
	for _, r := range w.rows {
		if r.level == 0 && r.path == "" {
			inside = r.page == pageBuild && r.dynamic == "" && r.kind == ""
			continue
		}
		if (inside || r.path != "") && (r.dynamic != "" || r.kind != "") {
			rows = append(rows, r)
		}
	}
	return rows
}

// kindRow is the sidebar's row of kind, and whether the sidebar has one.
func kindRow(w *window, kind string) (row, bool) {
	for _, r := range w.rows {
		if r.kind == kind {
			return r, true
		}
	}
	return row{}, false
}

// contentHit is the control labeled label furthest right, the page's rather than the
// sidebar's when both show the same words.
func (d *windowDriver) contentHit(label string) gfx.Hit {
	d.t.Helper()
	return d.sideHit(label, func(hit, found gfx.Hit) bool { return hit.Bounds.X > found.Bounds.X })
}

// sidebarHit is the control labeled label furthest left, the sidebar's rather than the page's
// when both show the same words.
func (d *windowDriver) sidebarHit(label string) gfx.Hit {
	d.t.Helper()
	return d.sideHit(label, func(hit, found gfx.Hit) bool { return hit.Bounds.X < found.Bounds.X })
}

// sideHit is the control labeled label that better prefers over every other one.
func (d *windowDriver) sideHit(label string, better func(hit, found gfx.Hit) bool) gfx.Hit {
	d.t.Helper()
	var found gfx.Hit
	ok := false
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() && (!ok || better(hit, found)) {
			found, ok = hit, true
		}
	}
	if !ok {
		d.t.Fatalf("no control labeled %q", label)
	}
	return found
}

// TestBuildKindIsOneRowThatOpensItsPage keeps a kind's pages out of the sidebar however many
// there are: one row below Build, Execution, Deployment stands for them, counts them and does
// not expand, and choosing it opens the kind's page, as the Toolchains and Debuggers pages
// are laid out, on its first page.
func TestBuildKindIsOneRowThatOpensItsPage(t *testing.T) {
	const count = 8
	w, d := buildPagesWindow(t, count)
	w.sess.open[pageBuild] = true
	d.until("the kind's row", func() bool { return len(buildRows(w)) > 0 })
	rows := buildRows(w)
	if len(rows) != 1 || rows[0].kind != "buildSystem" || rows[0].group || rows[0].expanded || rows[0].count != count || rows[0].level != 1 {
		t.Fatalf("rows below Build = %+v, want one build systems row of %d pages right below it", rows, count)
	}
	d.clickHit(d.sidebarHit(kindTitle(i18n.English, "buildSystem")))
	d.until("the kind's page", func() bool { return w.shownKind() == "buildSystem" && d.text(w.dynamic.pages[1].Title) })
	if w.dynamicPage != w.dynamic.pages[0].Key {
		t.Fatalf("the kind's row opened %q, want the first page %q", w.dynamicPage, w.dynamic.pages[0].Key)
	}
	if r, _ := kindRow(w, "buildSystem"); !w.rowSelected(r) {
		t.Fatal("the kind's row is not selected while its page shows")
	}
	first := w.dynamic.pages[0].Contributors[0].PluginID
	d.until("the first page's settings", func() bool {
		if w.pluginSettings.failed != nil {
			t.Fatal(w.pluginSettings.failed)
		}
		return w.pluginSettings.loaded && w.pluginSettings.id == first && d.wrapped("Parallel jobs")
	})
	for index := range w.dynamic.pages {
		if title := w.dynamic.pages[index].Title; !d.has(title) {
			t.Fatalf("the kind's page does not list %q", title)
		}
	}
	if total := kindPageCount(i18n.English, count); !d.text(total) {
		t.Fatalf("the kind's page does not count its pages as %q", total)
	}
	if !d.has(i18n.Shared(i18n.English, "desktop.buildSettings.kindFilter")) {
		t.Fatal("the kind's page has no filter")
	}
}

// TestBuildPageNamesAKindAndOpensItsPage checks the Build page's row for a kind: it names the
// first pages and counts them, and opens the kind's page on its first page.
func TestBuildPageNamesAKindAndOpensItsPage(t *testing.T) {
	const count = kindNames + 2
	w, d := buildPagesWindow(t, count)
	separator := i18n.Shared(i18n.English, "desktop.buildSettings.listSeparator")
	var names []string
	for _, page := range w.dynamic.pages[:kindNames] {
		names = append(names, page.Title)
	}
	desc := i18n.SharedFormat(i18n.English, "desktop.buildSettings.directoryKindMore", map[string]string{"names": strings.Join(names, separator), "count": formatCount(count)})
	d.until("the kind's row", func() bool { return d.text(desc) })
	d.clickHit(d.contentHit(kindTitle(i18n.English, "buildSystem")))
	d.until("the kind's page", func() bool { return w.shownKind() == "buildSystem" })
	if w.dynamicPage != w.dynamic.pages[0].Key || !w.sess.open[pageBuild] {
		t.Fatalf("the kind's row opened %q, want the first page %q with Build open", w.dynamicPage, w.dynamic.pages[0].Key)
	}
}

// TestBuildKindFilterKeepsThePagesItMatchesAndTheKindRemembersOne filters the kind's list by
// a plugin's name, opens the one page it keeps, and opens that page again when the kind's row
// is chosen after another page.
func TestBuildKindFilterKeepsThePagesItMatchesAndTheKindRemembersOne(t *testing.T) {
	const count = 8
	w, d := buildPagesWindow(t, count)
	w.openKind("buildSystem")
	d.until("the kind's page", func() bool { return w.shownKind() == "buildSystem" && d.has(w.dynamic.pages[1].Title) })
	w.kinds[kindIndex("buildSystem")].query = "Builder 05"
	// The filter shows once a frame is painted: clicking a row before that would hit a row
	// the filtered list no longer has.
	d.until("the filtered list", func() bool { return !d.has(w.dynamic.pages[1].Title) })
	pages := w.kindPages("buildSystem", "Builder 05")
	if len(pages) != 1 || pages[0].Contributors[0].PluginID != "dev.example.bs05" {
		t.Fatalf("the filter kept %d pages, want the one Builder 05 contributes to", len(pages))
	}
	key := pages[0].Key
	d.click(pages[0].Title)
	d.until("the chosen page", func() bool { return w.dynamicPage == key })
	if w.shownKind() != "buildSystem" {
		t.Fatalf("choosing a page in the list left the kind's page for %q", w.dynamicPage)
	}
	w.selectSettingsPage(pageGeneral, "")
	d.until("another page", func() bool { return w.shownKind() == "" && d.has(kindTitle(i18n.English, "buildSystem")) })
	d.clickHit(d.sidebarHit(kindTitle(i18n.English, "buildSystem")))
	d.until("the kind's page again", func() bool { return w.shownKind() == "buildSystem" })
	if w.dynamicPage != key {
		t.Fatalf("the kind opened %q again, want the page it showed last, %q", w.dynamicPage, key)
	}
}

// TestSearchListsOnlyTheKindPagesItMatches lists a plugin page under a kind only when the
// search matched it, not because it matched the kind, whose row stands for its pages; choosing
// the page opens it on the kind's page.
func TestSearchListsOnlyTheKindPagesItMatches(t *testing.T) {
	const count = 8
	w, d := buildPagesWindow(t, count)
	target := w.dynamic.pages[5]
	w.searchField.SetText(target.Title)
	d.until("the matched page", func() bool { return len(buildRows(w)) > 0 })
	var pages []string
	for _, r := range buildRows(w) {
		if r.dynamic != "" {
			pages = append(pages, r.dynamic)
		}
	}
	if len(pages) != 1 || pages[0] != target.Key {
		t.Fatalf("the search for %q listed pages %v, want only %q", target.Title, pages, target.Key)
	}
	w.searchField.SetText(kindTitle(i18n.English, "buildSystem"))
	d.until("the kind's row", func() bool { _, ok := kindRow(w, "buildSystem"); return ok })
	for _, r := range buildRows(w) {
		if r.dynamic != "" {
			t.Fatalf("matching the kind listed its page %+v", r)
		}
	}
	w.searchField.SetText(target.Title)
	// A search's row is named with the path to its page.
	label := ""
	d.until("the matched page again", func() bool {
		for _, r := range buildRows(w) {
			if r.dynamic == target.Key {
				label = w.rowLabel(r)
			}
		}
		return label != "" && d.has(label)
	})
	d.clickHit(d.sidebarHit(label))
	d.until("the page", func() bool { return w.dynamicPage == target.Key })
	if w.shownKind() != "buildSystem" || w.query != "" {
		t.Fatalf("choosing the search's row showed kind %q with search %q, want the build systems page with the search ended", w.shownKind(), w.query)
	}
}
