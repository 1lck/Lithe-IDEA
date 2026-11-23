package settingswindow

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/vivaui/viva/gfx"
)

const marketTestSVG = `<svg viewBox="0 0 24 24"><path fill="#548AF7" d="M2 2H22V22H2Z"/><circle fill="#FFFFFF" cx="12" cy="12" r="4"/></svg>`

func marketIconFixture(plugins []core.MarketplacePlugin, load func(context.Context, string) (gfx.Icon, error), report func(error)) *window {
	w := newWindow(NewController(Options{
		Marketplace:     func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
		MarketplaceIcon: load, MarketplaceIconError: report,
	}), Values{})
	w.sess.page, w.pluginTab = pagePlugins, pluginTabMarketplace
	w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil)
	return w
}

// waitForMarketIconFrame waits on the driver's actual repaint event. Its local
// deadline fails a missing completion without sleeps or a detached UI driver.
func waitForMarketIconFrame(d *windowDriver, what string, condition func() bool) {
	d.t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for {
		d.pump()
		if condition() {
			return
		}
		select {
		case <-d.driver.Wakes():
		case <-deadline.C:
			d.t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func TestMarketplaceSVGReplacesInitialsAndSharesTheRead(t *testing.T) {
	const address = "https://raw.githubusercontent.com/example/icons/main/brand.svg"
	url := address
	plugins := []core.MarketplacePlugin{
		{ID: "dev.lithe.test.market-brand", Name: "Brand Icon", Icon: &url},
		{ID: "dev.lithe.test.market-absent", Name: "Fallback Example"},
	}
	started, release, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var startedOnce, stoppedOnce sync.Once
	var calls atomic.Int32
	w := marketIconFixture(plugins, func(ctx context.Context, got string) (gfx.Icon, error) {
		calls.Add(1)
		startedOnce.Do(func() { close(started) })
		defer stoppedOnce.Do(func() { close(stopped) })
		if got != address {
			return gfx.Icon{}, fmt.Errorf("unexpected icon URL %q", got)
		}
		select {
		case <-release:
			return pluginicons.CompileSVG("marketplace.svg", []byte(marketTestSVG))
		case <-ctx.Done():
			return gfx.Icon{}, ctx.Err()
		}
	}, nil)
	t.Cleanup(func() { stopsWithin(t, stopped, "the SVG read") })
	d := openWindow(t, w)
	stopsWithin(t, started, "the SVG start")
	if !d.text("BI") || !d.text("FE") {
		t.Fatal("loading and absent icons must show their initials")
	}
	close(release)
	waitForMarketIconFrame(d, "the SVG replacing both initials", func() bool { return !d.text("BI") })
	if !d.text("FE") || calls.Load() != 1 {
		t.Fatalf("fallback=%v, reads=%d; row and detail must share the SVG", d.text("FE"), calls.Load())
	}
	if err := d.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || d.text("BI") {
		t.Fatal("a subsequent paint lost or re-read the SVG")
	}
}

func TestMarketplaceSVGFailureIsCachedUntilRefresh(t *testing.T) {
	url := "https://raw.githubusercontent.com/example/icons/main/broken.svg"
	plugins := []core.MarketplacePlugin{{ID: "dev.lithe.test.market-broken", Name: "Broken Icon", Icon: &url}}
	var calls, reports atomic.Int32
	w := marketIconFixture(plugins, func(context.Context, string) (gfx.Icon, error) {
		calls.Add(1)
		return pluginicons.CompileSVG("marketplace.svg", []byte(`<svg><script/></svg>`))
	}, func(error) { reports.Add(1) })
	d := openWindow(t, w)
	waitForMarketIconFrame(d, "the failed icon", func() bool {
		entry := w.marketIcons.entries[url]
		return entry != nil && entry.done
	})
	for range 3 {
		if err := d.driver.Paint(); err != nil {
			t.Fatal(err)
		}
	}
	if !d.text("BI") || calls.Load() != 1 || reports.Load() != 1 {
		t.Fatalf("failed icon: initials=%v reads=%d reports=%d", d.text("BI"), calls.Load(), reports.Load())
	}
	w.market.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil)
	if err := d.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	waitForMarketIconFrame(d, "the refreshed icon", func() bool {
		entry := w.marketIcons.entries[url]
		return entry != nil && entry.done && calls.Load() == 2
	})
	if reports.Load() != 2 {
		t.Fatalf("a refreshed icon failure was not recorded: %d", reports.Load())
	}
}

func TestMarketplaceSVGReadsAreLazyBoundedAndCancelled(t *testing.T) {
	plugins := make([]core.MarketplacePlugin, 1000)
	for i := range plugins {
		url := fmt.Sprintf("https://raw.githubusercontent.com/example/icons/main/%d.svg", i)
		plugins[i] = core.MarketplacePlugin{ID: fmt.Sprintf("dev.lithe.test.market-%d", i), Name: fmt.Sprintf("Plugin %04d", i), Icon: &url}
	}
	started := make(chan struct{}, marketIconConcurrency)
	stopped := make(chan struct{}, marketIconConcurrency)
	release := make(chan struct{})
	var releaseOnce sync.Once
	var active, peak, total, reports atomic.Int32
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	w := marketIconFixture(plugins, func(ctx context.Context, _ string) (gfx.Icon, error) {
		n := active.Add(1)
		for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
		}
		total.Add(1)
		started <- struct{}{}
		defer func() { active.Add(-1); stopped <- struct{}{} }()
		<-ctx.Done()
		select {
		case <-release:
		case <-time.After(5 * time.Second):
			return gfx.Icon{}, fmt.Errorf("cancelled SVG read was not released")
		}
		return gfx.Icon{}, ctx.Err()
	}, func(error) { reports.Add(1) })
	d := openWindow(t, w)
	t.Cleanup(func() {
		d.driver.Close()
		releaseOnce.Do(func() { close(release) })
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for active.Load() != 0 {
			select {
			case <-stopped:
			case <-deadline.C:
				t.Error("icon workers did not stop after closing")
				return
			}
		}
	})
	for range marketIconConcurrency {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatal("visible icon reads did not start")
		}
	}
	if peak.Load() > marketIconConcurrency || len(w.marketIcons.entries) > marketIconCacheEntries || len(w.marketIcons.entries) >= len(plugins) {
		t.Fatalf("unbounded reads: peak=%d entries=%d", peak.Load(), len(w.marketIcons.entries))
	}
	w.sess.page = pageGeneral
	if err := d.driver.Paint(); err != nil {
		t.Fatal(err)
	}
	releaseOnce.Do(func() { close(release) })
	for range marketIconConcurrency {
		select {
		case <-stopped:
		case <-time.After(5 * time.Second):
			t.Fatal("leaving the marketplace did not cancel icon reads")
		}
	}
	if active.Load() != 0 || reports.Load() != 0 || len(w.marketIcons.entries) != 0 || total.Load() != marketIconConcurrency {
		t.Fatalf("after leaving: active=%d reports=%d entries=%d reads=%d", active.Load(), reports.Load(), len(w.marketIcons.entries), total.Load())
	}
}
