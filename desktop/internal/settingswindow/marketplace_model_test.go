package settingswindow

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

func TestMarketplaceFetchIsLazyAndCloseCancels(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	fetch := func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		<-ctx.Done()
		close(stopped)
		return marketplace.Snapshot{}, ctx.Err()
	}
	m := newMarketplaceState(fetch, func() {})
	select {
	case <-started:
		t.Fatal("marketplace fetched before opening")
	default:
	}
	m.start()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace did not start")
	}
	m.close()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("marketplace did not cancel")
	}
	m.drain()
	if m.status != marketIdle {
		t.Fatalf("closed state = %v", m.status)
	}
}

func TestMarketplaceSelectionSurvivesRefresh(t *testing.T) {
	m := newMarketplaceState(nil, func() {})
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "a"}, {ID: "b"}}}}, nil)
	m.selected = "b"
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "c"}, {ID: "b"}}}}, nil)
	if m.selected != "b" {
		t.Fatalf("selection = %q", m.selected)
	}
	if i := m.index[m.selected]; i != 1 || m.snapshot.Index.Plugins[i].ID != "b" {
		t.Fatal("refreshed selection points at the wrong plugin")
	}
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "c"}}}}, nil)
	if m.selected != "c" {
		t.Fatalf("removed selection = %q", m.selected)
	}
}

func TestMarketplaceReportsRejectedEntries(t *testing.T) {
	count := 0
	w := newWindow(NewController(Options{MarketplaceRejected: func(n int) { count += n }}), Values{})
	w.market.status = marketLoading
	w.market.results <- marketResult{snapshot: marketplace.Snapshot{Index: core.MarketplaceIndex{Rejected: []core.MarketplaceEntryRejection{{}}}}}
	w.marketWake()
	w.marketWake()
	if count != 1 {
		t.Fatalf("reported %d rejected entries, want one", count)
	}
}
