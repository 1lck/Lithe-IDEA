package settingswindow

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

func indexOf(ids ...string) marketplace.Snapshot {
	plugins := make([]core.MarketplacePlugin, len(ids))
	for i, id := range ids {
		plugins[i] = core.MarketplacePlugin{ID: id, Name: id}
	}
	return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}
}

func TestMarketplaceSourceSwitchCancelsAndIgnoresLateResult(t *testing.T) {
	started, release, oldDone := make(chan struct{}), make(chan struct{}), make(chan bool, 1)
	var once sync.Once
	releaseOld := func() { once.Do(func() { close(release) }) }
	t.Cleanup(releaseOld)
	w := newWindow(NewController(Options{
		Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
			close(started)
			<-release // A transport can finish after cancellation; the request must still lose.
			oldDone <- ctx.Err() != nil
			return indexOf("community"), nil
		},
		MarketplaceOfficial: func(context.Context) (marketplace.Snapshot, error) { return indexOf("official"), nil },
	}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("community fetch did not start")
	}
	w.market.chooseSource(1)
	d.until("the official index", func() bool { return w.market.status == marketReady && w.market.selected == "official" })
	if w.market.source != 1 {
		t.Fatalf("selected source=%d plugin=%q", w.market.source, w.market.selected)
	}
	releaseOld()
	select {
	case cancelled := <-oldDone:
		if !cancelled {
			t.Fatal("old fetch was not cancelled")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled community fetch did not finish")
	}
	for range 3 {
		time.Sleep(5 * time.Millisecond)
		w.inv.Invalidate()
		d.pump()
	}
	if w.market.source != 1 || w.market.selected != "official" {
		t.Fatal("late community result replaced the official index")
	}
}

func TestMarketplaceReportsDiscardedSourceFailure(t *testing.T) {
	want := errors.New("source failed")
	reported := make(chan error, 1)
	started := make(chan struct{})
	w := newWindow(NewController(Options{
		Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
			close(started)
			<-ctx.Done()
			return marketplace.Snapshot{}, want
		},
		MarketplaceOfficial: func(context.Context) (marketplace.Snapshot, error) { return indexOf("official"), nil },
		MarketplaceError:    func(err error) { reported <- err },
	}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("community fetch did not start")
	}
	w.market.chooseSource(1)
	d.until("the official index", func() bool { return w.market.status == marketReady })
	select {
	case err := <-reported:
		if !errors.Is(err, want) {
			t.Fatalf("discarded failure = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the failure of the replaced source was not reported")
	}
}

// Rapid switching keeps one fetch per source in flight: a request replaced before it ended
// is cancelled by its effect, and the source chosen last is the one that ends up shown.
func TestMarketplaceRapidSwitchingKeepsOneFetchPerSource(t *testing.T) {
	var running, peak [2]atomic.Int32
	var total atomic.Int32
	fetch := func(source int, id string) func(context.Context) (marketplace.Snapshot, error) {
		return func(ctx context.Context) (marketplace.Snapshot, error) {
			total.Add(1)
			now := running[source].Add(1)
			defer running[source].Add(-1)
			for {
				seen := peak[source].Load()
				if now <= seen || peak[source].CompareAndSwap(seen, now) {
					break
				}
			}
			select {
			case <-ctx.Done():
				return marketplace.Snapshot{}, ctx.Err()
			case <-time.After(30 * time.Millisecond):
				return indexOf(id), nil
			}
		}
	}
	w := newWindow(NewController(Options{Marketplace: fetch(0, "community"), MarketplaceOfficial: fetch(1, "official")}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	for _, source := range []int{1, 0, 1, 0, 1} {
		w.market.chooseSource(source)
		w.inv.Invalidate()
		d.pump()
	}
	d.until("the last source", func() bool { return w.market.status == marketReady && w.market.selected == "official" })
	if peak[0].Load() > 1 || peak[1].Load() > 1 {
		t.Fatalf("fetches in flight at once: community %d, official %d", peak[0].Load(), peak[1].Load())
	}
	if w.market.source != 1 {
		t.Fatalf("final source = %d", w.market.source)
	}
}

func TestMarketplaceFetchIsLazyAndCloseCancels(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	w := newWindow(NewController(Options{Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		<-ctx.Done()
		close(stopped)
		return marketplace.Snapshot{}, ctx.Err()
	}}), Values{})
	d := openWindow(t, w)
	select {
	case <-started:
		t.Fatal("marketplace fetched before opening")
	default:
	}
	w.requestPage(pagePlugins)
	d.pump()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace did not start")
	}
	// An open marketplace page starts its fetch again, so it is closed as the page is left.
	w.market.close()
	w.sess.page = pageGeneral
	w.inv.Invalidate()
	d.pump()
	stopsWithin(t, stopped, "the marketplace fetch")
	if w.market.status != marketIdle {
		t.Fatalf("closed state = %v", w.market.status)
	}
}

func TestMarketplaceSelectionSurvivesRefresh(t *testing.T) {
	m := newMarketplaceState(nil)
	m.apply(indexOf("a", "b"), nil)
	m.selected = "b"
	m.apply(indexOf("c", "b"), nil)
	if m.selected != "b" {
		t.Fatalf("selection = %q", m.selected)
	}
	if i := m.index[m.selected]; i != 1 || m.snapshot.Index.Plugins[i].ID != "b" {
		t.Fatal("refreshed selection points at the wrong plugin")
	}
	m.apply(indexOf("c"), nil)
	if m.selected != "c" {
		t.Fatalf("removed selection = %q", m.selected)
	}
}

func TestMarketplaceReportsRejectedEntries(t *testing.T) {
	var count atomic.Int32
	w := newWindow(NewController(Options{
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Rejected: []core.MarketplaceEntryRejection{{}}}}, nil
		},
		MarketplaceRejected: func(n int) { count.Add(int32(n)) },
	}), Values{})
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	d.until("the index", func() bool { return w.market.status == marketReady })
	for range 3 {
		w.inv.Invalidate()
		d.pump()
	}
	if count.Load() != 1 {
		t.Fatalf("reported %d rejected entries, want one", count.Load())
	}
}

func TestInstalledMarketplaceSourceWorksWithoutRemoteFetch(t *testing.T) {
	w := newWindow(NewController(Options{
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			t.Error("offline installed source requested a remote index")
			return marketplace.Snapshot{}, errors.New("offline")
		},
		MarketplaceInstalled: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "local", Name: "Local", LatestVersion: "0.10.0"}}}}, nil
		},
	}), Values{})
	w.market.chooseSource(2)
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	d.until("the installed index", func() bool { return w.market.status == marketReady })
	if w.market.source != 2 || w.market.selected != "local" {
		t.Fatalf("installed source=%d status=%d selected=%q error=%v", w.market.source, w.market.status, w.market.selected, w.market.err)
	}
}
