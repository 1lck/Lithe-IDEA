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
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// buildPageContributions are count enabled plugins, each with one setting on a build system
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
		fixture.Manifest["settings"] = []any{map[string]any{"id": "flag", "type": "boolean", "title": "Flag", "default": true, "page": map[string]string{"buildSystemID": id}, "section": "Options"}}
		manifest, err := json.Marshal(fixture.Manifest)
		if err != nil {
			t.Fatal(err)
		}
		contributions = append(contributions, core.SettingsContribution{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: "dev.example." + id, Version: "1.0.0"}, Enabled: true})
	}
	return contributions
}

// buildPagesWindow is an English settings window whose plugins put count build system pages
// under Build, Execution, Deployment, opened on that page and loaded.
func buildPagesWindow(t *testing.T, count int) (*window, *windowDriver) {
	t.Helper()
	contributions := buildPageContributions(t, count)
	client := core.NewClient()
	w := newWindow(NewController(Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, Language: func() i18n.Language { return i18n.English },
		SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, contributions)
		},
	}), Values{Theme: "dark"})
	w.sess.page = pageBuild
	d := openWindow(t, w, func(config *app.Config) { config.Height = 900 })
	d.until("the plugin pages", func() bool { return w.dynamic.loaded && len(w.dynamic.pages) == count })
	return w, d
}

// buildRows are the plugin rows below Build, Execution, Deployment: folders and their pages.
func buildRows(w *window) []row {
	var rows []row
	inside := false
	for _, r := range w.rows {
		if r.level == 0 {
			inside = r.page == pageBuild && r.dynamic == "" && r.folder == ""
			continue
		}
		if inside && (r.dynamic != "" || r.folder != "") {
			rows = append(rows, r)
		}
	}
	return rows
}

// contentHit is the control labeled label furthest right, the page's rather than the
// sidebar's when both show the same words.
func (d *windowDriver) contentHit(label string) gfx.Hit {
	d.t.Helper()
	var found gfx.Hit
	ok := false
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() && (!ok || hit.Bounds.X > found.Bounds.X) {
			found, ok = hit, true
		}
	}
	if !ok {
		d.t.Fatalf("no control labeled %q", label)
	}
	return found
}

// TestBuildKindWithFewPagesListsThemDirectly keeps a kind's pages below Build, Execution,
// Deployment while there are fewer than folderMin of them, as the settings hierarchy Note
// says, and the Build page's row for the kind opens its first page.
func TestBuildKindWithFewPagesListsThemDirectly(t *testing.T) {
	w, d := buildPagesWindow(t, folderMin-1)
	w.sess.open[pageBuild] = true
	d.until("the build pages in the sidebar", func() bool {
		count := 0
		for _, r := range buildRows(w) {
			if r.dynamic != "" {
				count++
			}
		}
		return count == folderMin-1
	})
	for _, r := range buildRows(w) {
		if r.folder != "" {
			t.Fatalf("row %+v: %d pages of a kind should not fold", r, folderMin-1)
		}
		if r.dynamic != "" && r.level != 1 {
			t.Fatalf("row %+v should be right below Build, Execution, Deployment", r)
		}
	}
	d.clickHit(d.contentHit(kindTitle(i18n.English, "buildSystem")))
	d.pump()
	if w.dynamicPage != w.dynamic.pages[0].Key || w.folderPage != "" {
		t.Fatalf("the kind's row opened page %q, folder %q; want the first page %q", w.dynamicPage, w.folderPage, w.dynamic.pages[0].Key)
	}
}

// TestBuildKindFoldsIntoAFolderThatListsSix folds folderMin or more pages of a kind into a
// folder: closed, the sidebar shows only the folder; open, it lists folderLimit pages and one
// row for all of them, which opens the folder's page.
func TestBuildKindFoldsIntoAFolderThatListsSix(t *testing.T) {
	const count = folderLimit + 2
	w, d := buildPagesWindow(t, count)
	w.sess.open[pageBuild] = true
	d.until("the folder row", func() bool { return len(buildRows(w)) > 0 })
	var folder []row
	for _, r := range buildRows(w) {
		if r.dynamic != "" {
			t.Fatalf("closed folder: page row %+v should be inside the folder", r)
		}
		if r.folder != "" {
			folder = append(folder, r)
		}
	}
	if len(folder) != 1 || folder[0].folder != "buildSystem" || !folder[0].group || folder[0].expanded || folder[0].count != count {
		t.Fatalf("folder rows = %+v, want one closed build system folder of %d pages", folder, count)
	}
	w.folders[kindIndex("buildSystem")] = true
	d.until("the folder's pages", func() bool {
		rows := buildRows(w)
		return len(rows) > 0 && rows[len(rows)-1].overflow > 0
	})
	rows := buildRows(w)
	if len(rows) != folderLimit+2 {
		t.Fatalf("rows = %+v, want the folder, %d pages and the row for all of them", rows, folderLimit)
	}
	for _, r := range rows[1 : folderLimit+1] {
		if r.dynamic == "" || r.level != 2 {
			t.Fatalf("row %+v should be a page inside the folder", r)
		}
	}
	all := rows[len(rows)-1]
	if all.overflow != count || all.folder != "buildSystem" {
		t.Fatalf("the last row %+v should stand for all %d pages", all, count)
	}
	label := i18n.SharedFormat(i18n.English, "desktop.buildSettings.folderAll", map[string]string{"count": formatCount(count)})
	if !d.has(label) {
		t.Fatalf("the sidebar does not show %q", label)
	}
	d.click(label)
	d.pump()
	if w.folderPage != "buildSystem" {
		t.Fatalf("the row for all pages opened folder %q, want the build system folder (%+v)", w.folderPage, all)
	}
}

// TestBuildPageNamesAKindAndOpensItsFolder checks the Build page's row for a folded kind: it
// names the first pages and counts them, and opens the folder's page, whose filter keeps the
// pages it matches; choosing one opens it with the folder open.
func TestBuildPageNamesAKindAndOpensItsFolder(t *testing.T) {
	const count = folderLimit + 2
	w, d := buildPagesWindow(t, count)
	separator := i18n.Shared(i18n.English, "desktop.buildSettings.listSeparator")
	var names []string
	for _, page := range w.dynamic.pages[:kindNames] {
		names = append(names, page.Title)
	}
	desc := i18n.SharedFormat(i18n.English, "desktop.buildSettings.directoryKindMore", map[string]string{"names": strings.Join(names, separator), "count": formatCount(count)})
	d.until("the kind's row", func() bool { return d.text(desc) })
	d.clickHit(d.contentHit(kindTitle(i18n.English, "buildSystem")))
	d.pump()
	if w.folderPage != "buildSystem" {
		t.Fatalf("the kind's row opened folder %q, want the build system folder", w.folderPage)
	}
	d.pump()
	for index := range w.dynamic.pages {
		if title := w.dynamic.pages[index].Title; !d.text(title) {
			t.Fatalf("the folder's page does not list %q", title)
		}
	}
	w.folderQuery = "Builder 05"
	// The filter shows once a frame is painted: clicking a row before that would hit a row
	// the filtered list no longer has.
	d.until("the filtered folder", func() bool { return !d.text(w.dynamic.pages[0].Title) })
	pages := w.folderPages("buildSystem")
	if len(pages) != 1 || pages[0].Contributors[0].PluginID != "dev.example.bs05" {
		t.Fatalf("the filter kept %d pages, want the one Builder 05 contributes to", len(pages))
	}
	key := pages[0].Key
	d.click(pages[0].Title)
	d.pump()
	if w.dynamicPage != key || w.folderPage != "" || !w.folders[kindIndex("buildSystem")] || !w.sess.open[pageBuild] {
		t.Fatalf("choosing the page opened %q (folder page %q, folder open %v), want %q with its folder open", w.dynamicPage, w.folderPage, w.folders, key)
	}
}
