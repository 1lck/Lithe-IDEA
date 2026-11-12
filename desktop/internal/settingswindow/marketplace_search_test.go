package settingswindow

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

// unusedFetch stands for a catalog the test has already put in place.
func unusedFetch(context.Context) (marketplace.Snapshot, error) {
	return marketplace.Snapshot{}, errors.New("the catalog was already loaded")
}

// searchWindow opens the marketplace page on an index of plugins named by names, ranked by
// rank without a debounce.
func searchWindow(t *testing.T, rank func(context.Context, string, []core.RankCandidate) ([]int, error), names ...string) (*window, *windowDriver) {
	t.Helper()
	w := newWindow(NewController(Options{MarketplaceRank: rank, Marketplace: unusedFetch}), Values{})
	w.market.search.delay = -1
	w.market.apply(indexOf(names...), nil)
	w.sess.page = pagePlugins
	return w, openWindow(t, w)
}

// ask types query into the marketplace's search the way the field would and paints.
func ask(d *windowDriver, query string) {
	d.w.marketQuery = query
	d.w.inv.Invalidate()
	d.pump()
}

func TestMarketplaceSearchCancelsStaleAndStartsLatest(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	releaseOld := func() { once.Do(func() { close(release) }) }
	t.Cleanup(releaseOld)
	rank := func(_ context.Context, query string, _ []core.RankCandidate) ([]int, error) {
		switch query {
		case "first":
			close(started)
			<-release
			return []int{0}, nil
		case "latest":
			return []int{1}, nil
		}
		t.Errorf("unexpected search %q", query)
		return nil, errors.New("unexpected search")
	}
	w, d := searchWindow(t, rank, "first", "latest")
	s := &w.market.search
	ask(d, "first")
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("first search did not start")
	}
	// Two inputs between paints: only the last one is asked for.
	w.marketQuery = "middle"
	w.marketQuery = "latest"
	w.inv.Invalidate()
	d.pump()
	releaseOld()
	d.until("the latest search", func() bool { return s.query == "latest" && !s.loading })
	if s.failed || len(s.matches) != 1 || s.matches[0] != 1 || w.market.selected != "latest" {
		t.Fatalf("latest result=%v selected=%q", s.matches, w.market.selected)
	}
	ask(d, "  ")
	if len(s.visible()) != 2 || s.loading {
		t.Fatal("blank input did not restore the complete catalog")
	}
	ask(d, strings.Repeat("x", marketQueryMaxBytes+1))
	if !s.tooLong || s.loading {
		t.Fatal("oversized search was not rejected before Core")
	}
}

func TestMarketplaceSearchRejectsInvalidCoreIndices(t *testing.T) {
	reported := make(chan error, 1)
	rank := func(context.Context, string, []core.RankCandidate) ([]int, error) { return []int{1}, nil }
	w := newWindow(NewController(Options{MarketplaceRank: rank, Marketplace: unusedFetch, MarketplaceError: func(err error) { reported <- err }}), Values{})
	w.market.search.delay = -1
	w.market.apply(indexOf("a"), nil)
	w.sess.page = pagePlugins
	d := openWindow(t, w)
	ask(d, "A")
	d.until("the failed search", func() bool { return w.market.search.failed })
	select {
	case err := <-reported:
		if !errors.Is(err, errMarketRankIndices) {
			t.Fatalf("reported = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the invalid result was not reported")
	}
}

// A field may change after a run ends but before the paint takes its result. That result
// must not replace the new query's selection.
func TestMarketplaceSearchInputChangesBeforeTake(t *testing.T) {
	var asked atomic.Int32
	rank := func(_ context.Context, query string, _ []core.RankCandidate) ([]int, error) {
		asked.Add(1)
		if query == "old" {
			return []int{0}, nil
		}
		return []int{1}, nil
	}
	w, d := searchWindow(t, rank, "old", "new")
	s := &w.market.search
	ask(d, "old")
	// Let the run end without painting, then change the field before the next paint takes it.
	deadline := time.Now().Add(5 * time.Second)
	for asked.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("old search did not run")
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	w.marketQuery = "new"
	w.collect()
	if s.query == "old" && len(s.matches) != 0 {
		t.Fatalf("stale result applied: query=%q matches=%v", s.query, s.matches)
	}
	w.inv.Invalidate()
	d.pump()
	d.until("the new search", func() bool { return s.query == "new" && !s.loading })
	if s.failed || len(s.matches) != 1 || s.matches[0] != 1 || w.market.selected != "new" {
		t.Fatalf("new result=%v selected=%q", s.matches, w.market.selected)
	}
}
