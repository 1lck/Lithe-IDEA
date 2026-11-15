package settingswindow

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

const marketQueryMaxBytes = 4096

var errMarketRankIndices = errors.New("marketplace search returned invalid indices")

// marketSearchKey names one request of the search: the text asked for and the catalog it
// ranks, so a new catalog asks again for the same text.
type marketSearchKey struct {
	query   string
	catalog uint64
}

// marketSearchJob is what one run ranks: written on the window thread when the key
// changes and taken once by the run.
type marketSearchJob struct {
	query      string
	candidates []core.RankCandidate
}

// marketplaceSearch holds presentation state only. Matching and ranking belong to Core;
// the request is a page Effect keyed by the query and the catalog, so newer input cancels
// the run before it and an older answer never reaches the list.
type marketplaceSearch struct {
	rank                            func(context.Context, string, []core.RankCandidate) ([]int, error)
	report                          func(error)
	candidates                      []core.RankCandidate
	all, matches                    []int
	query                           string
	empty                           bool
	known, loading, tooLong, failed bool
	catalog                         uint64
	effect                          *ui.EffectState[[]int, marketSearchKey]
	jobMu                           sync.Mutex
	job                             marketSearchJob
	want                            marketSearchKey
	requested                       bool
	// Negative means no debounce in deterministic tests.
	delay time.Duration
}

// bind makes the effect once the search has its final address.
func (s *marketplaceSearch) bind() {
	s.effect = ui.NewEffect[[]int, marketSearchKey](s.run)
}

func (s *marketplaceSearch) invalidate() {
	s.requested = false
	s.known, s.loading, s.tooLong, s.failed = false, false, false, false
	s.matches = nil
}

func (s *marketplaceSearch) setCatalog(plugins []core.MarketplacePlugin) {
	s.invalidate()
	s.catalog++
	s.candidates = make([]core.RankCandidate, len(plugins))
	s.all = make([]int, len(plugins))
	for i, plugin := range plugins {
		s.candidates[i] = core.RankCandidate{Name: plugin.Name, Path: plugin.ID}
		s.all[i] = i
	}
}

func (s *marketplaceSearch) update(query string) {
	if s.rank == nil || s.known && s.query == query {
		return
	}
	s.requested = false
	s.query, s.known, s.loading, s.tooLong, s.failed = query, true, false, false, false
	s.matches = nil
	s.empty = strings.TrimSpace(query) == ""
	if s.empty {
		return
	}
	if len(query) > marketQueryMaxBytes {
		s.tooLong = true
		return
	}
	s.loading = true
	s.want = marketSearchKey{query: query, catalog: s.catalog}
	s.requested = true
	s.jobMu.Lock()
	s.job = marketSearchJob{query: query, candidates: s.candidates}
	s.jobMu.Unlock()
}

// run is the ranking: after the debounce it asks Core for the plugins that match.
func (s *marketplaceSearch) run(ctx context.Context) ([]int, error) {
	s.jobMu.Lock()
	job := s.job
	s.jobMu.Unlock()
	delay := s.delay
	if delay == 0 {
		delay = 180 * time.Millisecond
	}
	if delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			// log-exempt: 用户取消：新输入或关闭页面结束防抖。
			return nil, ctx.Err()
		}
	}
	operation, done := context.WithTimeout(ctx, 10*time.Second)
	defer done()
	indices, err := s.rank(operation, job.query, job.candidates)
	if err == nil {
		seen := make(map[int]bool, len(indices))
		for _, index := range indices {
			if index < 0 || index >= len(job.candidates) || seen[index] {
				err = errMarketRankIndices
				break
			}
			seen[index] = true
		}
	}
	// An answer that arrives after the request was replaced is dropped with the run, so
	// its failure is reported here.
	if ctx.Err() != nil && err != nil && !errors.Is(err, context.Canceled) && s.report != nil {
		s.report(err)
	}
	return indices, err
}

// take applies the finished ranking on the window thread at the start of a paint. The
// field may have changed after the run ended but before this paint: an answer for a query
// that is no longer in it is dropped, and the paint asks again for the one that is.
func (s *marketplaceSearch) take(m *marketplaceState, currentInput string) {
	if s.effect == nil || !s.requested {
		return
	}
	indices, err, ok := s.effect.Take()
	if !ok || s.query != currentInput {
		return
	}
	s.loading = false
	if err != nil {
		s.failed = true
		if !errors.Is(err, context.Canceled) && s.report != nil {
			s.report(err)
		}
		return
	}
	s.matches = indices
	found := false
	for _, index := range s.matches {
		if m.snapshot.Index.Plugins[index].ID == m.selected {
			found = true
			break
		}
	}
	if !found {
		m.selected = ""
		if len(s.matches) > 0 {
			m.selected = m.snapshot.Index.Plugins[s.matches[0]].ID
		}
	}
}

// declare keeps the wanted ranking alive in the paint.
func (s *marketplaceSearch) declare(c ui.C) {
	if s.effect != nil && s.requested {
		ui.Effect(c, s.effect, s.want)
	}
}

func (s *marketplaceSearch) visible() []int {
	if s.rank == nil || s.empty || !s.known {
		return s.all
	}
	return s.matches
}
