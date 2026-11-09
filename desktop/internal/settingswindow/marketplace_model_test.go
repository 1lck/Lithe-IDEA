package settingswindow

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

func TestMarketplaceSourceSwitchCancelsAndIgnoresLateResult(t *testing.T) {
	started, release, oldDone, ready := make(chan struct{}), make(chan struct{}), make(chan bool, 1), make(chan struct{}, 2)
	var once sync.Once
	releaseOld := func() { once.Do(func() { close(release) }) }
	t.Cleanup(releaseOld)
	m := newMarketplaceState(func(ctx context.Context) (marketplace.Snapshot, error) {
		close(started)
		<-release // A transport can finish after cancellation; the generation must still win.
		oldDone <- ctx.Err() != nil
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "community"}}}}, nil
	}, func() {
		select {
		case ready <- struct{}{}:
		default:
		}
	})
	m.official = func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "official"}}}}, nil
	}
	m.start()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-started:
	case <-timer.C:
		t.Fatal("community fetch did not start")
	}
	m.chooseSource(1)
	select {
	case <-ready:
	case <-timer.C:
		t.Fatal("official fetch did not finish")
	}
	m.drain()
	if m.source != 1 || m.selected != "official" {
		t.Fatalf("selected source=%d plugin=%q", m.source, m.selected)
	}
	releaseOld()
	select {
	case cancelled := <-oldDone:
		if !cancelled {
			t.Fatal("old fetch was not cancelled")
		}
	case <-timer.C:
		t.Fatal("cancelled community fetch did not finish")
	}
	select {
	case <-ready:
	case <-timer.C:
		t.Fatal("old source did not report completion")
	}
	m.drain()
	if m.source != 1 || m.selected != "official" {
		t.Fatal("late community result replaced the official index")
	}
	m.close()
}

func TestMarketplaceLogsDiscardedSourceFailure(t *testing.T) {
	m := newMarketplaceState(nil, func() {})
	m.generation = 2
	m.running = 1
	want := errors.New("source failed")
	var reported error
	m.reportDiscarded = func(err error) { reported = err }
	m.results <- marketResult{generation: 1, err: want}
	m.drain()
	if !errors.Is(reported, want) {
		t.Fatalf("discarded failure = %v", reported)
	}
}

func TestMarketplaceRapidSwitchingBoundsWorkers(t *testing.T) {
	type request struct {
		source  string
		release chan struct{}
	}
	started, wake, stop := make(chan request, 4), make(chan struct{}, 4), make(chan struct{})
	fetch := func(source string) func(context.Context) (marketplace.Snapshot, error) {
		return func(context.Context) (marketplace.Snapshot, error) {
			r := request{source: source, release: make(chan struct{})}
			started <- r
			select {
			case <-r.release:
			case <-stop:
			}
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: source}}}}, nil
		}
	}
	m := newMarketplaceState(fetch("community"), func() { wake <- struct{}{} })
	m.official = fetch("official")
	t.Cleanup(func() {
		m.close()
		close(stop)
		finished := make(chan struct{})
		go func() { m.workers.Wait(); close(finished) }()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("marketplace workers did not stop")
		}
	})
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	next := func() request {
		t.Helper()
		select {
		case r := <-started:
			return r
		case <-timer.C:
			t.Fatal("request did not start")
			return request{}
		}
	}
	m.start()
	first := next()
	m.chooseSource(1)
	second := next()
	m.chooseSource(0)
	m.chooseSource(1)
	if m.running != marketMaxInFlight || !m.pending {
		t.Fatalf("running=%d pending=%v", m.running, m.pending)
	}
	select {
	case r := <-started:
		t.Fatalf("unexpected extra worker: %s", r.source)
	default:
	}
	close(first.release)
	select {
	case <-wake:
		m.drain()
	case <-timer.C:
		t.Fatal("first worker did not complete")
	}
	third := next()
	if third.source != "official" {
		t.Fatalf("queued source = %q", third.source)
	}
	close(second.release)
	close(third.release)
	for m.running > 0 {
		select {
		case <-wake:
			m.drain()
		case <-timer.C:
			t.Fatal("workers did not complete")
		}
	}
	if m.selected != "official" || m.pending {
		t.Fatalf("final source=%q pending=%v", m.selected, m.pending)
	}
}

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
	w.market.running = 1
	w.market.results <- marketResult{snapshot: marketplace.Snapshot{Index: core.MarketplaceIndex{Rejected: []core.MarketplaceEntryRejection{{}}}}}
	w.marketWake()
	w.marketWake()
	if count != 1 {
		t.Fatalf("reported %d rejected entries, want one", count)
	}
}

func TestInstalledMarketplaceSourceWorksWithoutRemoteFetch(t *testing.T) {
	ready := make(chan struct{}, 1)
	m := newMarketplaceState(func(context.Context) (marketplace.Snapshot, error) {
		t.Error("offline installed source requested a remote index")
		return marketplace.Snapshot{}, errors.New("offline")
	}, func() { ready <- struct{}{} })
	m.installed = func(context.Context) (marketplace.Snapshot, error) {
		return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "local", Name: "Local", LatestVersion: "0.10.0"}}}}, nil
	}
	t.Cleanup(m.close)
	m.chooseSource(2)
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case <-ready:
	case <-timer.C:
		t.Fatal("installed source did not complete")
	}
	m.drain()
	if m.source != 2 || m.status != marketReady || m.selected != "local" {
		t.Fatalf("installed source=%d status=%d selected=%q error=%v", m.source, m.status, m.selected, m.err)
	}
}
