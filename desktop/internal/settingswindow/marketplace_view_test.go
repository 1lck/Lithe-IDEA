package settingswindow

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

func TestMarketplaceSourceSelectorLoadsTheChosenIndex(t *testing.T) {
	makeFetch := func(id string) func(context.Context) (marketplace.Snapshot, error) {
		return func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: id, Name: id}}}}, nil
		}
	}
	w := newWindow(NewController(Options{Marketplace: makeFetch("community"), MarketplaceOfficial: makeFetch("official")}), Values{})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	w.sess.page = pagePlugins
	w.inv.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	waitReady := func(id string) {
		t.Helper()
		for w.market.status != marketReady || w.market.selected != id {
			select {
			case <-driver.Wakes():
				if err := driver.Pump(); err != nil {
					t.Fatal(err)
				}
			case <-timer.C:
				t.Fatalf("source %s did not load", id)
			}
		}
	}
	waitReady("community")
	click := func(id gfx.ID) {
		t.Helper()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		t.Fatalf("source control %v not visible", id)
	}
	click(marketSourceScope.At(2))
	click(marketSourceScope.At(1))
	waitReady("official")
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
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		w.market.close()
		select {
		case <-started:
			select {
			case <-stopped:
			case <-time.After(5 * time.Second):
				t.Error("community fetch did not stop")
			}
		default:
		}
		driver.Close()
	})
	w.sess.page = pagePlugins
	w.inv.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-started:
	case <-timer.C:
		t.Fatal("community fetch did not start")
	}
	click := func(id gfx.ID) {
		t.Helper()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
		t.Fatalf("source control %v is not visible while loading", id)
	}
	click(marketSourceScope.At(2))
	click(marketSourceScope.At(1))
	select {
	case <-stopped:
	case <-timer.C:
		t.Fatal("old source was not cancelled")
	}
	for w.market.status != marketReady || w.market.selected != "official" {
		select {
		case <-driver.Wakes():
			if err := driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-timer.C:
			t.Fatal("official source did not load")
		}
	}
}

func TestMarketplaceSearchUsesCoreAndOpensMatchingSelection(t *testing.T) {
	client := core.NewClient()
	plugins := []core.MarketplacePlugin{{ID: "dev.example.cargo", Name: "Cargo"}, {ID: "dev.example.go", Name: "Go Support"}, {ID: "dev.example.lua", Name: "Lua Support"}}
	w := newWindow(NewController(Options{Marketplace: func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
	}, MarketplaceRank: client.RankNames}), Values{})
	w.market.search.delay = -1
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	w.sess.page = pagePlugins
	w.inv.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	wait := func(ready func() bool) {
		t.Helper()
		for !ready() {
			select {
			case <-driver.Wakes():
				if err := driver.Pump(); err != nil {
					t.Fatal(err)
				}
			case <-timer.C:
				t.Fatal("marketplace search did not settle")
			}
		}
	}
	wait(func() bool { return w.market.status == marketReady })
	var rect gfx.Rect
	for _, hit := range driver.Snapshot().Hits {
		if hit.ID == marketQueryID {
			rect = hit.Bounds
			break
		}
	}
	if rect.Width == 0 {
		t.Fatal("marketplace search field is missing")
	}
	if err := driver.Click(rect.X+rect.Width/2, rect.Y+rect.Height/2); err != nil {
		t.Fatal(err)
	}
	if err := driver.Type("Lua"); err != nil {
		t.Fatal(err)
	}
	wait(func() bool {
		return w.market.search.known && w.market.search.query == "Lua" && !w.market.search.loading
	})
	if w.market.search.failed || w.market.selected != "dev.example.lua" || len(w.market.search.visible()) != 1 {
		t.Fatalf("Lua search = %+v selection=%q", w.market.search.visible(), w.market.selected)
	}
	if _, err := driver.ShortcutChord(gfx.ModifierMeta, 'a'); err != nil {
		t.Fatal(err)
	}
	if err := driver.Type("dev.example.go"); err != nil {
		t.Fatal(err)
	}
	wait(func() bool { return w.market.search.query == "dev.example.go" && !w.market.search.loading })
	if w.market.search.failed || w.market.selected != "dev.example.go" || len(w.market.search.visible()) != 1 {
		t.Fatalf("ID search = %+v selection=%q", w.market.search.visible(), w.market.selected)
	}
}

func TestMarketplaceWindowLoadsAndVirtualizes(t *testing.T) {
	plugins := make([]core.MarketplacePlugin, 1000)
	for i := range plugins {
		plugins[i] = core.MarketplacePlugin{ID: fmt.Sprintf("plugin-%04d", i), Name: fmt.Sprintf("Plugin %04d", i), Author: "Author", Description: fmt.Sprintf("Description %04d", i), LatestVersion: "1.0"}
	}
	release := make(chan struct{})
	started := make(chan struct{})
	stopped := make(chan struct{})
	fetch := func(ctx context.Context) (marketplace.Snapshot, error) {
		defer close(stopped)
		close(started)
		select {
		case <-release:
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
		case <-ctx.Done():
			return marketplace.Snapshot{}, ctx.Err()
		}
	}
	w := newWindow(NewController(Options{Marketplace: fetch, Dark: func() bool { return true }}), Values{Theme: "dark"})
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		w.market.close()
		driver.Close()
		select {
		case <-started:
			select {
			case <-stopped:
			case <-time.After(5 * time.Second):
				t.Error("marketplace worker did not stop")
			}
		default:
		}
	})
	select {
	case <-started:
		t.Fatal("marketplace loaded before its page was opened")
	default:
	}
	w.sess.page = pagePlugins
	w.inv.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-driver.Wakes():
	default:
	}
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace fetch did not start")
	}
	close(release)
	select {
	case <-driver.Wakes():
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace did not request repaint")
	}
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	snap := driver.Snapshot()
	rows := 0
	var second gfx.Rect
	for _, hit := range snap.Hits {
		if i, ok := hit.ID.In(marketRows); ok {
			rows++
			if i == 1 {
				second = hit.Bounds
			}
		}
	}
	if rows < 2 || rows > 20 {
		t.Fatalf("painted %d rows for 1000 plugins", rows)
	}
	if second.Width == 0 || second.Height == 0 {
		t.Fatal("second plugin is not selectable")
	}
	x, y := second.X+second.Width/2, second.Y+second.Height/2
	if err := driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := driver.Release(x, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, label := range driver.Snapshot().Labels {
		if strings.Contains(label.Value, "Description 0001") {
			found = true
		}
	}
	if !found {
		t.Fatal("selecting the second plugin did not update its details")
	}
	marketListAccessible := false
	for _, hit := range driver.Snapshot().Hits {
		if hit.Container && hit.Role == gfx.RoleListBox && hit.Label == "Marketplace" {
			marketListAccessible = true
		}
	}
	if !marketListAccessible {
		t.Fatal("marketplace has no accessible list container")
	}
	if err := driver.Key(gfx.KeyDown, 0); err != nil {
		t.Fatal(err)
	}
	found = false
	for _, label := range driver.Snapshot().Labels {
		if strings.Contains(label.Value, "Description 0002") {
			found = true
		}
	}
	if !found {
		t.Fatal("keyboard selection did not update the details")
	}
	if err := driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: 1800, Precise: true}); err != nil {
		t.Fatal(err)
	}
	rows, minimum := 0, len(plugins)
	for _, hit := range driver.Snapshot().Hits {
		if i, ok := hit.ID.In(marketRows); ok {
			rows++
			minimum = min(minimum, i)
		}
	}
	if minimum == 0 || rows > 20 {
		t.Fatalf("after scrolling: first row %d, painted %d", minimum, rows)
	}
	if err := driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: -1800, Precise: true}); err != nil {
		t.Fatal(err)
	}
	selected := false
	for _, hit := range driver.Snapshot().Hits {
		if i, ok := hit.ID.In(marketRows); ok && i == 2 && hit.Selected {
			selected = true
		}
	}
	if !selected {
		t.Fatal("selection was lost after scrolling away and back")
	}
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
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		w.market.close()
		driver.Close()
		select {
		case <-started:
			select {
			case <-stopped:
			case <-time.After(5 * time.Second):
				t.Error("marketplace worker did not stop")
			}
		default:
		}
	})
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace fetch did not start")
	}
	var general gfx.Rect
	for _, hit := range driver.Snapshot().Hits {
		if i, ok := hit.ID.In(rowScope); ok && i == int(pageGeneral) {
			general = hit.Bounds
			break
		}
	}
	if general.Width == 0 {
		t.Fatal("general page is not visible")
	}
	x, y := general.X+general.Width/2, general.Y+general.Height/2
	if err := driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := driver.Release(x, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("leaving page did not cancel marketplace fetch")
	}
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
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		w.market.close()
		driver.Close()
		select {
		case <-started:
			select {
			case <-stopped:
			case <-time.After(5 * time.Second):
				t.Error("marketplace worker did not stop")
			}
		default:
		}
	})
	w.search.SetText("general")
	w.requestPlugins.Store(true)
	w.inv.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("plugin page did not start marketplace fetch")
	}
	if w.sess.page != pagePlugins || w.search.Text() != "" {
		t.Fatal("plugin request did not select the visible plugin page")
	}
}

// The split is tested through the real page's hit routing and layout, not by
// invoking its state directly. No timer or native window is required.
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
						t.Fatal("unexpected fetch")
						return marketplace.Snapshot{}, nil
					},
					MarketplaceResized: func(width float32) { saved = append(saved, width) },
				}
				w := newWindow(NewController(options), Values{Theme: theme})
				w.sess.page = pagePlugins
				w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "demo", Name: "Demo", Author: "Author", Description: "Detail text for a plugin"}}}}, nil)
				driver, err := app.NewDriver(w.config(), nil)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { w.market.close(); driver.Close() })
				divider := func() gfx.Rect {
					t.Helper()
					for _, hit := range driver.Snapshot().Hits {
						if hit.ID == marketDividerID {
							return hit.Bounds
						}
					}
					t.Fatal("resize handle missing")
					return gfx.Rect{}
				}
				checkDetail := func() {
					t.Helper()
					r := divider()
					for _, label := range driver.Snapshot().Labels {
						if strings.HasPrefix(label.Value, "Detail") {
							if label.Bounds.X < r.X+r.Width/2 {
								t.Fatalf("detail overlaps divider: %+v / %+v", label.Bounds, r)
							}
							return
						}
					}
					t.Fatal("detail text missing")
				}
				r := divider()
				if r.Width != marketDividerHitWidth || w.marketSplit.Size(w.marketExtent) != 320 {
					t.Fatalf("initial divider = %+v, width=%v", r, w.marketSplit.Size(w.marketExtent))
				}
				x, y := r.X+r.Width/2, r.Y+r.Height/2
				if err := driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if err := driver.Move(x+100, y); err != nil {
					t.Fatal(err)
				}
				if len(saved) != 0 {
					t.Fatal("drag wrote preferences before release")
				}
				if w.marketSplit.Size(w.marketExtent) != 420 {
					t.Fatalf("drag size = %v", w.marketSplit.Size(w.marketExtent))
				}
				checkDetail()
				if err := driver.Release(x+100, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if len(saved) != 1 || saved[0] != 420 {
					t.Fatalf("completed resize saved %v", saved)
				}
				reopened := newWindow(NewController(options), Values{Theme: theme, MarketplaceWidth: saved[0]})
				if got := reopened.marketSplit.Size(719); got != 420 {
					t.Fatalf("reopened width = %v, want 420", got)
				}
				w.market.apply(w.market.snapshot, nil)
				w.inv.Invalidate()
				if err := driver.Pump(); err != nil {
					t.Fatal(err)
				}
				checkDetail()
				if err := driver.Resize(760, 680); err != nil {
					t.Fatal(err)
				}
				if got := w.marketSplit.Size(w.marketExtent); got != 358 {
					t.Fatalf("narrow size = %v, want 358", got)
				}
				checkDetail()
				// A click or outward drag at the temporary boundary must not erase
				// the wider preference chosen before the window was narrowed.
				r = divider()
				x, y = r.X+r.Width/2, r.Y+r.Height/2
				if err := driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if err := driver.Move(x+30, y); err != nil {
					t.Fatal(err)
				}
				if err := driver.Release(x+30, y, gfx.PointerButtonPrimary); err != nil {
					t.Fatal(err)
				}
				if len(saved) != 1 {
					t.Fatal("a drag against the narrow-window boundary erased the preference")
				}
				if err := driver.Resize(960, 680); err != nil {
					t.Fatal(err)
				}
				if got := w.marketSplit.Size(w.marketExtent); got != 420 {
					t.Fatalf("resize forgot saved width: %v", got)
				}
				if len(saved) != 1 {
					t.Fatal("window resizing persisted a temporary clamp")
				}
				if err := driver.Key(gfx.KeyEnd, 0); err != nil {
					t.Fatal(err)
				}
				if got := w.marketSplit.Size(w.marketExtent); got != 520 {
					t.Fatalf("End key width = %v", got)
				}
				if len(saved) != 2 || saved[1] != 520 {
					t.Fatalf("keyboard resize saved %v", saved)
				}
			})
		}
	}
}
