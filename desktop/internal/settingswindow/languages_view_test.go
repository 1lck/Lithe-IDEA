package settingswindow

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// languagePageContributions are enabled synthetic plugins, dev.example.<language> for each
// of languages, each with one setting on the page of its language, so the real Core projects
// one page for each under Languages & Frameworks.
func languagePageContributions(t *testing.T, languages ...string) []core.SettingsContribution {
	t.Helper()
	contributions := make([]core.SettingsContribution, 0, len(languages))
	for _, language := range languages {
		contributions = append(contributions, languagePageContribution(t, "dev.example."+language, language))
	}
	return contributions
}

// languagePageContribution is the enabled synthetic plugin id, titled "Test <id's last part>
// plugin", with one setting, "Run checks", on the page of language.
func languagePageContribution(t *testing.T, id, language string) core.SettingsContribution {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Manifest map[string]any }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	fixture.Manifest["id"] = id
	fixture.Manifest["displayName"] = "Test " + strings.TrimPrefix(id, "dev.example.") + " plugin"
	fixture.Manifest["settings"] = []any{
		map[string]any{"id": "checks", "type": "boolean", "title": "Run checks", "default": true, "page": map[string]string{"languageID": language}, "section": "Options"},
	}
	delete(fixture.Manifest, "settingActions")
	manifest, err := json.Marshal(fixture.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	return core.SettingsContribution{Manifest: manifest, Owner: core.PluginSettingsOwner{PluginID: id, Version: "1.0.0"}, Enabled: true}
}

// languagesWindow is an English settings window on the General page whose synthetic plugins
// contribute a page for each of languages, with the catalog loaded. adjust changes its options.
func languagesWindow(t *testing.T, adjust func(*Options), languages ...string) (*window, *windowDriver) {
	t.Helper()
	return contributedWindow(t, adjust, languagePageContributions(t, languages...), len(languages))
}

// contributedWindow is an English settings window on the General page with the plugin
// settings contributions, once the catalog lists its pages. adjust changes its options.
func contributedWindow(t *testing.T, adjust func(*Options), contributions []core.SettingsContribution, pages int) (*window, *windowDriver) {
	t.Helper()
	client := core.NewClient()
	opts := Options{
		Text: func() *i18n.Messages { return i18n.For(i18n.English) }, Language: func() i18n.Language { return i18n.English },
		PluginSettings:     newBuildFormSource(t, client, contributions),
		SettingsNavigation: client.SettingsNavigation,
		SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
			return client.SettingsPages(ctx, contributions, "")
		},
	}
	if adjust != nil {
		adjust(&opts)
	}
	w := newWindow(NewController(opts), Values{Theme: "dark"})
	d := openWindow(t, w, func(config *app.Config) { config.Height = 900 })
	d.until("the plugin pages", func() bool { return w.dynamic.loaded && len(w.dynamic.pages) == pages })
	return w, d
}

// sidebarRowHit is the sidebar's row labeled label itself, the widest of its controls, rather
// than the chevron before a group's title, which is labeled the same and only folds it.
func (d *windowDriver) sidebarRowHit(label string) gfx.Hit {
	d.t.Helper()
	var found gfx.Hit
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() && hit.Bounds.X < sidebarWidth && hit.Bounds.Width > found.Bounds.Width {
			found = hit
		}
	}
	if found.Bounds.Width == 0 {
		d.t.Fatalf("no sidebar row labeled %q", label)
	}
	return found
}

// TestLanguagesPageListsItsPagesAndOpensThem keeps Languages & Frameworks from showing the page
// the new client does not offer: its row opens its own page, which lists every plugin page
// under it with the plugins that provide it and the state of a language's server, opens the
// one clicked, and is opened again from the breadcrumb above that page.
func TestLanguagesPageListsItsPagesAndOpensThem(t *testing.T) {
	languages := []string{"alpha", "beta", "gamma"}
	states := map[string]string{"dev.example.alpha": "ready", "dev.example.beta": "failed"}
	w, d := languagesWindow(t, func(opts *Options) {
		opts.LanguageServerState = func(id string) string { return states[id] }
	}, languages...)
	title := titleOf(&w.text.Settings, pageLanguages)
	d.until("the Languages & Frameworks row", func() bool { return d.has(title) })
	d.clickHit(d.sidebarRowHit(title))
	d.until("the Languages & Frameworks page", func() bool {
		return w.sess.page == pageLanguages && w.dynamicPage == "" && d.wrapped(i18n.Shared(i18n.English, "desktop.languageSettings.intro"))
	})
	if d.wrapped(w.text.Settings.PageLater) {
		t.Fatal("Languages & Frameworks still shows the page the new client does not offer")
	}
	if !w.sess.open[pageLanguages] {
		t.Fatal("choosing the Languages & Frameworks row did not expand it")
	}
	pages := w.languagePages()
	if len(pages) != len(languages) {
		t.Fatalf("the page lists %d pages, want %d", len(pages), len(languages))
	}
	for _, page := range pages {
		if !d.text(page.Title) {
			t.Fatalf("the page does not list %q", page.Title)
		}
		provided := i18n.SharedFormat(i18n.English, "desktop.buildSettings.providedBy", map[string]string{"plugin": page.Contributors[0].Title})
		if !d.text(provided) {
			t.Fatalf("the row of %q does not say %q", page.Title, provided)
		}
	}
	for _, state := range []string{"ready", "failed", ""} {
		words, _ := languageStateWords(i18n.English, state)
		if server := i18n.SharedFormat(i18n.English, "desktop.languageSettings.serverState", map[string]string{"state": words}); !d.text(server) {
			t.Fatalf("no row says %q", server)
		}
	}

	d.clickHit(d.contentHit(pages[1].Title))
	d.until("the clicked page", func() bool {
		return w.sess.page == pageLanguages && w.dynamicPage == pages[1].Key && w.pluginSettings.loaded && d.wrapped("Run checks")
	})
	crumbs := w.appendCrumbs(nil)
	if len(crumbs) != 2 || crumbs[0].page != pageLanguages || !crumbs[0].link {
		t.Fatalf("breadcrumb above a plugin page = %+v, want Languages & Frameworks as a link", crumbs)
	}
	d.clickHit(d.contentHit(title))
	d.until("the Languages & Frameworks page again", func() bool {
		return w.sess.page == pageLanguages && w.dynamicPage == "" && d.text(pages[0].Title)
	})
}

// TestLanguagesPageWithoutPluginPages shows where the pages come from while no plugin
// contributes one, and its button opens the marketplace.
func TestLanguagesPageWithoutPluginPages(t *testing.T) {
	w, d := languagesWindow(t, func(opts *Options) {
		opts.Marketplace = func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil }
	})
	w.selectSettingsPage(pageLanguages, "")
	empty := i18n.Shared(i18n.English, "desktop.languageSettings.empty")
	d.until("the empty Languages & Frameworks page", func() bool { return d.wrapped(empty) })
	if d.wrapped(w.text.Settings.PageLater) {
		t.Fatal("Languages & Frameworks still shows the page the new client does not offer")
	}
	if d.wrapped(i18n.Shared(i18n.English, "desktop.languageSettings.intro")) {
		t.Fatal("the empty page asks to choose a page it does not list")
	}
	d.click(i18n.Shared(i18n.English, "desktop.languageSettings.browse"))
	d.until("the marketplace", func() bool { return w.sess.page == pagePlugins && w.pluginTab == pluginTabMarketplace })
}

// TestLanguagePageDoesNotRepeatItsDirectoryRow keeps a language page from repeating what its
// row in the directory says: the page one plugin provides opens on that plugin's settings,
// without a chooser of the one plugin or a card of its language server's state. The chooser
// is there while two plugins contribute to the page, the one way to switch between them.
func TestLanguagePageDoesNotRepeatItsDirectoryRow(t *testing.T) {
	contributions := append(languagePageContributions(t, "alpha", "beta"), languagePageContribution(t, "dev.example.beta-extra", "beta"))
	w, d := contributedWindow(t, func(opts *Options) {
		opts.LanguageServerState = func(string) string { return "ready" }
	}, contributions, 2)
	open := func(language string) {
		t.Helper()
		key := ""
		for _, page := range w.languagePages() {
			for _, contribution := range page.Contributors {
				if contribution.PluginID == "dev.example."+language {
					key = page.Key
				}
			}
		}
		if key == "" {
			t.Fatalf("no page of %s", language)
		}
		w.selectSettingsPage(pageLanguages, key)
		d.until("the page of "+language, func() bool {
			return w.dynamicPage == key && w.contributorID != "" && w.pluginSettings.id == w.contributorID &&
				w.pluginSettings.loaded && d.wrapped("Run checks")
		})
	}
	chooser := i18n.Shared(i18n.English, "desktop.pluginSettings.contributor")
	ready, _ := languageStateWords(i18n.English, "ready")

	open("alpha")
	if d.has(chooser) {
		t.Fatal("the page one plugin provides chooses between plugins")
	}
	if d.text(ready) {
		t.Fatalf("the page repeats its directory row's language server state %q", ready)
	}

	open("beta")
	if !d.has(chooser) {
		t.Fatal("the page two plugins contribute to has no chooser between them")
	}
	if d.text(ready) {
		t.Fatalf("the page repeats its directory row's language server state %q", ready)
	}
}
