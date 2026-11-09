package settingswindow

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const marketQueryMaxBytes = 4096

var errMarketRankIndices = errors.New("marketplace search returned invalid indices")

type marketSearchResult struct {
	generation uint64
	indices    []int
	err        error
	reported   bool
}

// marketplaceSearch holds presentation state only. Matching and ranking belong
// to Core; one cancellable request runs at a time and newer input replaces it.
type marketplaceSearch struct {
	rank                                              func(context.Context, string, []core.RankCandidate) ([]int, error)
	wake                                              func()
	report                                            func(error)
	candidates                                        []core.RankCandidate
	all, matches                                      []int
	query                                             string
	empty                                             bool
	known, pending, running, loading, tooLong, failed bool
	generation                                        uint64
	cancel                                            context.CancelFunc
	results                                           chan marketSearchResult
	workers                                           sync.WaitGroup
	// Negative means no debounce in deterministic tests.
	delay time.Duration
}

func (s *marketplaceSearch) invalidate() {
	s.generation++
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.known, s.pending, s.loading, s.tooLong, s.failed = false, false, false, false, false
	s.matches = nil
}

func (s *marketplaceSearch) setCatalog(plugins []core.MarketplacePlugin) {
	s.invalidate()
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
	s.generation++
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.query, s.known, s.pending, s.loading, s.tooLong, s.failed = query, true, false, false, false, false
	s.matches = nil
	s.empty = strings.TrimSpace(query) == ""
	if s.empty {
		return
	}
	if len(query) > marketQueryMaxBytes {
		s.tooLong = true
		return
	}
	s.pending, s.loading = true, true
	s.launch()
}

func (s *marketplaceSearch) launch() {
	if !s.pending || s.running {
		return
	}
	if s.results == nil {
		s.results = make(chan marketSearchResult, 1)
	}
	s.pending, s.running = false, true
	query, candidates, generation := s.query, s.candidates, s.generation
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	rank, results, wake, report := s.rank, s.results, s.wake, s.report
	delay := s.delay
	if delay == 0 {
		delay = 180 * time.Millisecond
	}
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：新输入或关闭页面结束防抖。
				results <- marketSearchResult{generation: generation, err: ctx.Err()}
				if wake != nil {
					wake()
				}
				return
			}
		}
		operation, done := context.WithTimeout(ctx, 10*time.Second)
		defer done()
		indices, err := rank(operation, query, candidates)
		if err == nil {
			seen := make(map[int]bool, len(indices))
			for _, index := range indices {
				if index < 0 || index >= len(candidates) || seen[index] {
					err = errMarketRankIndices
					break
				}
				seen[index] = true
			}
		}
		reported := ctx.Err() != nil && err != nil && !errors.Is(err, context.Canceled) && report != nil
		if reported {
			report(err)
		}
		results <- marketSearchResult{generation: generation, indices: indices, err: err, reported: reported}
		if wake != nil {
			wake()
		}
	}()
}

func (s *marketplaceSearch) drain(m *marketplaceState, currentInput string) {
	if s.results == nil {
		return
	}
	select {
	case result := <-s.results:
		s.running, s.cancel = false, nil
		if result.generation != s.generation || s.query != currentInput {
			if result.err != nil && !result.reported && !errors.Is(result.err, context.Canceled) && s.report != nil {
				s.report(result.err)
			}
			// log-exempt: 用户取消：旧查询已被新输入或关闭页面替代。
			if s.query != currentInput && m.status == marketReady {
				s.update(currentInput)
			} else {
				s.launch()
			}
			return
		}
		s.loading = false
		if result.err != nil {
			s.failed = true
			if !result.reported && !errors.Is(result.err, context.Canceled) && s.report != nil {
				s.report(result.err)
			}
			return
		}
		s.matches = result.indices
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
	default:
	}
}

func (s *marketplaceSearch) visible() []int {
	if s.rank == nil || s.empty || !s.known {
		return s.all
	}
	return s.matches
}
