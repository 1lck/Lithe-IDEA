package settingswindow

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// primaryModifier is the platform's command key.
func primaryModifier() gfx.Modifiers {
	if isDarwin() {
		return gfx.ModifierMeta
	}
	return gfx.ModifierControl
}

// stopsWithin fails the test unless stopped closes in a bounded time.
func stopsWithin(t *testing.T, stopped <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatalf("%s did not stop", what)
	}
}

// Plugin auto-update is opt-in. The settings gear must expose both states
// without opening a download or requiring any installed plugin.
func TestMarketplaceAutoUpdateMenuToggle(t *testing.T) {
	var changed []bool
	w := newWindow(NewController(Options{
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
		SetAutoUpdatePlugins: func(enabled bool) {
			changed = append(changed, enabled)
		},
	}), Values{})
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	d.click(words("desktop.pluginSettings.title"))
	d.pump()
	d.click(words("desktop.marketplace.enableAutoUpdates"))
	d.pump()
	if !w.sess.values.AutoUpdatePlugins || len(changed) != 1 || !changed[0] {
		t.Fatalf("enabling auto-update: value=%v callbacks=%v", w.sess.values.AutoUpdatePlugins, changed)
	}
	d.click(words("desktop.pluginSettings.title"))
	d.pump()
	d.click(words("desktop.marketplace.disableAutoUpdates"))
	d.pump()
	if w.sess.values.AutoUpdatePlugins || len(changed) != 2 || changed[1] {
		t.Fatalf("disabling auto-update: value=%v callbacks=%v", w.sess.values.AutoUpdatePlugins, changed)
	}
}

func TestMarketplaceSourceSelectorLoadsTheChosenIndex(t *testing.T) {
	makeFetch := func(id string) func(context.Context) (marketplace.Snapshot, error) {
		return func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: id, Name: id}}}}, nil
		}
	}
	w := newWindow(NewController(Options{Marketplace: makeFetch("community"), MarketplaceOfficial: makeFetch("official")}), Values{})
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	d.until("the community index", func() bool { return w.market.status == marketReady && w.market.selected == "community" })
	d.click(i18n.Shared(i18n.English, "native.pluginRepository"))
	d.click(i18n.Shared(i18n.English, "desktop.marketplace.officialSource"))
	d.until("the official index", func() bool { return w.market.status == marketReady && w.market.selected == "official" })
	if w.market.source != 1 {
		t.Fatalf("source = %d", w.market.source)
	}
}

func TestMarketplaceSourceSelectorRemainsAvailableWhileLoading(t *testing.T) {
	started, stopped := make(chan struct{}), make(chan struct{})
	w := newWindow(NewController(Options{
		Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
			close(started)
			<-ctx.Done()
			close(stopped)
			return marketplace.Snapshot{}, ctx.Err()
		},
		MarketplaceOfficial: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "official", Name: "official"}}}}, nil
		},
	}), Values{})
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("community fetch did not start")
	}
	d.click(i18n.Shared(i18n.English, "native.pluginRepository"))
	d.click(i18n.Shared(i18n.English, "desktop.marketplace.officialSource"))
	stopsWithin(t, stopped, "the old source")
	d.until("the official index", func() bool { return w.market.status == marketReady && w.market.selected == "official" })
}

func TestMarketplaceSearchUsesCoreAndOpensMatchingSelection(t *testing.T) {
	client := core.NewClient()
	plugins := []core.MarketplacePlugin{{ID: "dev.example.cargo", Name: "Cargo"}, {ID: "dev.example.go", Name: "Go Support"}, {ID: "dev.example.lua", Name: "Lua Support"}}
	w := newWindow(NewController(Options{Marketplace: func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
	}, MarketplaceRank: client.RankNames}), Values{})
	w.market.search.delay = -1
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	d.until("the index", func() bool { return w.market.status == marketReady })
	d.click(i18n.Shared(i18n.English, "native.searchPlugins"))
	d.typeText("Lua")
	d.until("the Lua search", func() bool {
		return w.market.search.known && w.market.search.query == "Lua" && !w.market.search.loading
	})
	if w.market.search.failed || w.market.selected != "dev.example.lua" || len(w.market.search.visible()) != 1 {
		t.Fatalf("Lua search = %+v selection=%q", w.market.search.visible(), w.market.selected)
	}
	if _, err := d.driver.ShortcutChord(primaryModifier(), 'a'); err != nil {
		t.Fatal(err)
	}
	d.typeText("dev.example.go")
	d.until("the ID search", func() bool { return w.market.search.query == "dev.example.go" && !w.market.search.loading })
	if w.market.search.failed || w.market.selected != "dev.example.go" || len(w.market.search.visible()) != 1 {
		t.Fatalf("ID search = %+v selection=%q", w.market.search.visible(), w.market.selected)
	}
}

// pluginRows lists the plugin rows the list painted, by their index in the index.
func (d *windowDriver) pluginRows() map[int]gfx.Hit {
	rows := map[int]gfx.Hit{}
	for _, hit := range d.driver.Snapshot().Hits {
		var index int
		if hit.Role == gfx.RoleOption {
			if n, _ := fmt.Sscanf(hit.Label, "Plugin %d", &index); n == 1 {
				rows[index] = hit
			}
		}
	}
	return rows
}

func TestMarketplaceWindowLoadsAndVirtualizes(t *testing.T) {
	plugins := make([]core.MarketplacePlugin, 1000)
	for i := range plugins {
		plugins[i] = core.MarketplacePlugin{ID: fmt.Sprintf("plugin-%04d", i), Name: fmt.Sprintf("Plugin %04d", i), Author: "Author", Description: fmt.Sprintf("Description %04d", i), LatestVersion: "1.0"}
	}
	release := make(chan struct{})
	started := make(chan struct{})
	fetch := func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		select {
		case <-release:
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
		case <-ctx.Done():
			return marketplace.Snapshot{}, ctx.Err()
		}
	}
	w := newWindow(NewController(Options{Marketplace: fetch, Dark: func() bool { return true }}), Values{Theme: "dark"})
	d := openWindow(t, w)
	select {
	case <-started:
		t.Fatal("marketplace loaded before its page was opened")
	default:
	}
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	w.inv.Invalidate()
	d.pump()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace fetch did not start")
	}
	close(release)
	d.until("the index", func() bool { return w.market.status == marketReady })
	rows := d.pluginRows()
	if len(rows) < 2 || len(rows) > 20 {
		t.Fatalf("painted %d rows for 1000 plugins", len(rows))
	}
	second, ok := rows[1]
	if !ok || second.Bounds.Width == 0 {
		t.Fatal("second plugin is not selectable")
	}
	d.clickHit(second)
	if !d.textContaining("Description 0001") {
		t.Fatal("selecting the second plugin did not update its details")
	}
	listAccessible := false
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleListBox && hit.Label == "Marketplace" {
			listAccessible = true
		}
	}
	if !listAccessible {
		t.Fatal("marketplace has no accessible list")
	}
	d.key(gfx.KeyDown)
	if !d.textContaining("Description 0002") {
		t.Fatal("keyboard selection did not update the details")
	}
	x, y := second.Bounds.X+second.Bounds.Width/2, second.Bounds.Y+second.Bounds.Height/2
	if err := d.driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: 1800, Precise: true}); err != nil {
		t.Fatal(err)
	}
	rows = d.pluginRows()
	minimum := len(plugins)
	for index := range rows {
		minimum = min(minimum, index)
	}
	if minimum == 0 || len(rows) > 20 {
		t.Fatalf("after scrolling: first row %d, painted %d", minimum, len(rows))
	}
	if err := d.driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: -1800, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if hit, ok := d.pluginRows()[2]; !ok || !hit.Selected {
		t.Fatal("selection was lost after scrolling away and back")
	}
}

// ScrollTo must apply in the same frame that requests it; the former Viva
// List bug could leave all requested rows beyond the old viewport until a
// pointer move caused another paint (#1820).
func TestMarketplaceScrollToTopPaintsTheFirstRowImmediately(t *testing.T) {
	plugins := make([]core.MarketplacePlugin, 120)
	for i := range plugins {
		plugins[i] = core.MarketplacePlugin{
			ID: fmt.Sprintf("plugin-%03d", i), Name: fmt.Sprintf("Plugin %d", i),
			LatestVersion: "1.0",
		}
	}
	w := newWindow(NewController(Options{
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
		},
	}), Values{})
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	d.until("the catalog", func() bool { return w.market.status == marketReady })
	start := d.pluginRows()[1]
	x, y := start.Bounds.X+start.Bounds.Width/2, start.Bounds.Y+start.Bounds.Height/2
	if err := d.driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: 2000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if _, visible := d.pluginRows()[0]; visible {
		t.Fatal("scrolling did not leave the initial viewport")
	}
	w.market.list.ScrollTo(0, ui.ListStart)
	w.inv.Invalidate()
	d.pump()
	if row, ok := d.pluginRows()[0]; !ok || row.Bounds.Height <= 0 {
		t.Fatal("scroll-to-top did not paint the first row on the requested frame")
	}
}

// textContaining reports whether a label of the frame contains part.
func (d *windowDriver) textContaining(part string) bool {
	for _, label := range d.driver.Snapshot().Labels {
		if strings.Contains(label.Value, part) {
			return true
		}
	}
	return false
}

func TestMarketplaceWindowCancelsWhenLeavingPage(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	w := newWindow(NewController(Options{Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		<-ctx.Done()
		close(stopped)
		return marketplace.Snapshot{}, ctx.Err()
	}, Dark: func() bool { return true }}), Values{Theme: "dark"})
	w.sess.page = pagePlugins
	w.pluginTab = pluginTabMarketplace
	d := openWindow(t, w)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace fetch did not start")
	}
	d.click("General")
	stopsWithin(t, stopped, "the marketplace fetch after leaving the page")
}

func TestMarketplaceRequestSwitchesOpenSettingsWindow(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	w := newWindow(NewController(Options{Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		<-ctx.Done()
		close(stopped)
		return marketplace.Snapshot{}, ctx.Err()
	}, Dark: func() bool { return true }}), Values{Theme: "dark"})
	d := openWindow(t, w)
	w.searchField.SetText("general")
	w.pluginTab = pluginTabMarketplace
	w.requestPage(pagePlugins)
	d.pump()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("plugin page did not start marketplace fetch")
	}
	if w.sess.page != pagePlugins || w.searchField.Text() != "" {
		t.Fatal("plugin request did not select the visible plugin page")
	}
}

// The divider is tested through the real page's hit routing and layout, not by invoking its
// state directly. No timer or native window is required.
func TestMarketplaceDividerDragResizeAndRestore(t *testing.T) {
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"light", "dark"} {
			name := "en"
			if language == i18n.Chinese {
				name = "zh"
			}
			t.Run(name+"/"+theme, func(t *testing.T) {
				var saved []float32
				options := Options{
					Language: func() i18n.Language { return language },
					Text:     func() *i18n.Messages { return i18n.For(language) },
					Marketplace: func(context.Context) (marketplace.Snapshot, error) {
						t.Error("unexpected fetch")
						return marketplace.Snapshot{}, nil
					},
					MarketplaceResized: func(width float32) { saved = append(saved, width) },
				}
				w := newWindow(NewController(options), Values{Theme: theme})
				w.sess.page = pagePlugins
				w.pluginTab = pluginTabMarketplace
				w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "demo", Name: "Demo", Author: "Author", Description: "Detail text for a plugin"}}}}, nil)
				d := openWindow(t, w)
				handle := i18n.Shared(language, "settings.resizePlugins")
				checkDetail := func() {
					t.Helper()
					r := d.hit(handle).Bounds
					for _, label := range d.driver.Snapshot().Labels {
						if strings.HasPrefix(label.Value, "Detail") {
							if label.Bounds.X < r.X+r.Width/2 {
								t.Fatalf("detail overlaps divider: %+v / %+v", label.Bounds, r)
							}
							return
						}
					}
					t.Fatal("detail text missing")
				}
				r := d.hit(handle).Bounds
				if w.marketApplied != 320 {
					t.Fatalf("initial divider = %+v, width=%v", r, w.marketApplied)
				}
				x, y := r.X+r.Width/2, r.Y+r.Height/2
				if err := d.driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if err := d.driver.Move(x+100, y); err != nil {
					t.Fatal(err)
				}
				if len(saved) != 0 {
					t.Fatal("drag wrote preferences before release")
				}
				if w.marketApplied != 420 {
					t.Fatalf("drag size = %v", w.marketApplied)
				}
				checkDetail()
				if err := d.driver.Release(x+100, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				d.pump()
				if len(saved) != 1 || saved[0] != 420 {
					t.Fatalf("completed resize saved %v", saved)
				}
				reopened := newWindow(NewController(options), Values{Theme: theme, MarketplaceWidth: saved[0]})
				if reopened.marketApplied != 420 {
					t.Fatalf("reopened width = %v, want 420", reopened.marketApplied)
				}
				checkDetail()
				if err := d.driver.Resize(760, 680); err != nil {
					t.Fatal(err)
				}
				// The 234-point baseline sidebar leaves 525 pixels: less the divider
				// and the room the detail keeps.
				if w.marketApplied != 357 {
					t.Fatalf("narrow size = %v, want 357", w.marketApplied)
				}
				checkDetail()
				// A click or outward drag at the temporary boundary must not erase the wider
				// preference chosen before the window was narrowed.
				r = d.hit(handle).Bounds
				x, y = r.X+r.Width/2, r.Y+r.Height/2
				if err := d.driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if err := d.driver.Move(x+30, y); err != nil {
					t.Fatal(err)
				}
				if err := d.driver.Release(x+30, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				d.pump()
				if len(saved) != 1 {
					t.Fatalf("a drag against the narrow-window boundary erased the preference: %v", saved)
				}
				if err := d.driver.Resize(960, 680); err != nil {
					t.Fatal(err)
				}
				if w.marketApplied != 420 {
					t.Fatalf("resize forgot saved width: %v", w.marketApplied)
				}
				if len(saved) != 1 {
					t.Fatal("window resizing persisted a temporary clamp")
				}
				d.key(gfx.KeyEnd)
				d.pump()
				if w.marketApplied != 520 {
					t.Fatalf("End key width = %v", w.marketApplied)
				}
				if len(saved) != 2 || saved[1] != 520 {
					t.Fatalf("keyboard resize saved %v", saved)
				}
			})
		}
	}
}

func TestMarketplaceShowsFailureError(t *testing.T) {
	t.Run("single source failure", func(t *testing.T) {
		const reason = "dial tcp 192.0.2.1:443: i/o timeout"
		w := newWindow(NewController(Options{
			Marketplace: func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{}, errors.New(reason)
			},
		}), Values{})
		w.sess.page = pagePlugins
		w.pluginTab = pluginTabMarketplace
		d := openWindow(t, w)
		d.until("marketplace failure", func() bool { return w.market.status == marketFailed })
		if !d.textContaining(i18n.Shared(i18n.English, "native.pluginMarketplaceIsNotAvailable")) {
			t.Fatal("unavailable heading missing")
		}
		if !d.textContaining(reason) {
			t.Fatalf("failure reason %q was hidden from the marketplace view", reason)
		}
	})

	t.Run("partial aggregate failure", func(t *testing.T) {
		const reason = "network is unreachable"
		w := newWindow(NewController(Options{
			Marketplace: func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "community", Name: "Community"}}}}, nil
			},
			MarketplaceOfficial: func(context.Context) (marketplace.Snapshot, error) {
				return marketplace.Snapshot{}, errors.New(reason)
			},
		}), Values{})
		w.sess.page = pagePlugins
		w.pluginTab = pluginTabMarketplace
		w.market.chooseSource(w.market.aggregateSource())
		d := openWindow(t, w)
		d.until("aggregate index", func() bool { return w.market.status == marketReady })
		if !d.textContaining(i18n.Shared(i18n.English, "desktop.marketplace.officialSource")) {
			t.Fatal("official source label missing from aggregate failure notice")
		}
		if !d.textContaining(reason) {
			t.Fatalf("partial failure reason %q was hidden from the marketplace view", reason)
		}
	})
}

func TestOpenMarketplaceWithoutSearch(t *testing.T) {
	query := ""
	w := newWindow(NewController(Options{
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
	}), Values{MarketplaceQuery: &query})
	w.sess.show(pagePlugins)
	d := openWindow(t, w)
	if w.pluginTab != pluginTabMarketplace || w.marketQuery != "" {
		t.Fatalf("opened plugins tab = %v, query = %q, want unfiltered Marketplace", w.pluginTab, w.marketQuery)
	}

	w.pluginTab = pluginTabInstalled
	w.marketQuery = "previous query"
	w.requestQuery("")
	w.requestPage(pagePlugins)
	d.pump()
	if w.pluginTab != pluginTabMarketplace || w.marketQuery != "" {
		t.Fatalf("reopened plugins tab = %v, query = %q, want unfiltered Marketplace", w.pluginTab, w.marketQuery)
	}
}
