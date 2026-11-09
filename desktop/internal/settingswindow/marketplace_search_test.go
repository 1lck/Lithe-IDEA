package settingswindow

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

func TestMarketplaceSearchCancelsStaleAndStartsLatest(t *testing.T) {
	started, release, wake := make(chan struct{}), make(chan struct{}), make(chan struct{}, 2)
	var once sync.Once
	releaseOld := func() { once.Do(func() { close(release) }) }
	m := newMarketplaceState(nil, func() {})
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "first", Name: "first"}, {ID: "latest", Name: "latest"}}}}, nil)
	s := &m.search
	s.delay = -1
	s.wake = func() { wake <- struct{}{} }
	s.rank = func(_ context.Context, query string, _ []core.RankCandidate) ([]int, error) {
		if query == "first" {
			close(started)
			<-release
			return []int{0}, nil
		}
		if query == "latest" {
			return []int{1}, nil
		}
		t.Errorf("unexpected search %q", query)
		return nil, errors.New("unexpected search")
	}
	t.Cleanup(func() {
		releaseOld()
		s.invalidate()
		finished := make(chan struct{})
		go func() { s.workers.Wait(); close(finished) }()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("search worker did not finish")
		}
	})
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	s.update("first")
	select {
	case <-started:
	case <-timer.C:
		t.Fatal("first search did not start")
	}
	s.update("middle")
	s.update("latest")
	if !s.running || !s.pending {
		t.Fatal("latest search was not queued behind the running one")
	}
	releaseOld()
	select {
	case <-wake:
		s.drain(m, "latest")
	case <-timer.C:
		t.Fatal("first search did not finish")
	}
	select {
	case <-wake:
		s.drain(m, "latest")
	case <-timer.C:
		t.Fatal("latest search did not finish")
	}
	if s.loading || s.failed || len(s.matches) != 1 || s.matches[0] != 1 || m.selected != "latest" {
		t.Fatalf("latest result=%v selected=%q", s.matches, m.selected)
	}
	s.update("  ")
	if len(s.visible()) != 2 || s.loading {
		t.Fatal("blank input did not restore the complete catalog")
	}
	s.update(strings.Repeat("x", marketQueryMaxBytes+1))
	if !s.tooLong || s.loading {
		t.Fatal("oversized search was not rejected before Core")
	}
}

func TestMarketplaceSearchRejectsInvalidCoreIndices(t *testing.T) {
	wake := make(chan struct{}, 1)
	m := newMarketplaceState(nil, func() {})
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "a", Name: "A"}}}}, nil)
	s := &m.search
	s.delay = -1
	s.wake = func() { wake <- struct{}{} }
	s.rank = func(context.Context, string, []core.RankCandidate) ([]int, error) { return []int{1}, nil }
	var reported error
	s.report = func(err error) { reported = err }
	t.Cleanup(func() {
		s.invalidate()
		finished := make(chan struct{})
		go func() { s.workers.Wait(); close(finished) }()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("search worker did not finish")
		}
	})
	s.update("A")
	select {
	case <-wake:
		s.drain(m, "A")
	case <-time.After(5 * time.Second):
		t.Fatal("invalid result did not return")
	}
	if !s.failed || !errors.Is(reported, errMarketRankIndices) {
		t.Fatalf("failure=%v reported=%v", s.failed, reported)
	}
}

// A field may change after a worker wakes the UI but before the frame drains
// its result. That result must not replace the new query's selection.
func TestMarketplaceSearchInputChangesBeforeDrain(t *testing.T) {
	wake := make(chan struct{}, 2)
	m := newMarketplaceState(nil, func() {})
	m.apply(marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{{ID: "old", Name: "old"}, {ID: "new", Name: "new"}}}}, nil)
	s := &m.search
	s.delay = -1
	s.wake = func() { wake <- struct{}{} }
	s.rank = func(_ context.Context, query string, _ []core.RankCandidate) ([]int, error) {
		if query == "old" {
			return []int{0}, nil
		}
		return []int{1}, nil
	}
	t.Cleanup(func() {
		s.invalidate()
		finished := make(chan struct{})
		go func() { s.workers.Wait(); close(finished) }()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("search worker did not finish")
		}
	})
	s.update("old")
	select {
	case <-wake:
	case <-time.After(5 * time.Second):
		t.Fatal("old search did not finish")
	}
	s.drain(m, "new")
	if s.query != "new" || !s.loading || len(s.matches) != 0 {
		t.Fatalf("stale result applied: query=%q loading=%v matches=%v", s.query, s.loading, s.matches)
	}
	select {
	case <-wake:
		s.drain(m, "new")
	case <-time.After(5 * time.Second):
		t.Fatal("new search did not finish")
	}
	if s.loading || s.failed || len(s.matches) != 1 || s.matches[0] != 1 || m.selected != "new" {
		t.Fatalf("new result=%v selected=%q", s.matches, m.selected)
	}
}
