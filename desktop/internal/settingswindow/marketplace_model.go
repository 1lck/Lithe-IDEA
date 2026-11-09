package settingswindow

import (
	"context"
	"errors"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

type marketStatus uint8

const (
	marketIdle marketStatus = iota
	marketLoading
	marketReady
	marketFailed
)

type marketResult struct {
	generation uint64
	snapshot   marketplace.Snapshot
	err        error
	reported   bool
}

const marketMaxInFlight = 2

// marketplaceState is owned by the settings window. Only the result channel is used
// by the background fetch; closing or leaving the page cancels and invalidates it.
type marketplaceState struct {
	fetch           func(context.Context) (marketplace.Snapshot, error)
	official        func(context.Context) (marketplace.Snapshot, error)
	installed       func(context.Context) (marketplace.Snapshot, error)
	reportDiscarded func(error)
	source          int
	wake            func()
	results         chan marketResult
	cancel          context.CancelFunc
	generation      uint64
	running         int
	pending         bool
	workers         sync.WaitGroup
	status          marketStatus
	snapshot        marketplace.Snapshot
	selected        string
	// index is rebuilt only when a new catalog arrives, not on every drag frame.
	index  map[string]int
	err    error
	search marketplaceSearch
}

func newMarketplaceState(fetch func(context.Context) (marketplace.Snapshot, error), wake func()) *marketplaceState {
	return &marketplaceState{fetch: fetch, wake: wake, results: make(chan marketResult, marketMaxInFlight)}
}
func (m *marketplaceState) start() {
	fetch := m.fetch
	if m.source == 1 {
		fetch = m.official
	} else if m.source == 2 {
		fetch = m.installed
	}
	if fetch == nil || m.status == marketLoading {
		return
	}
	m.generation++
	m.status, m.pending = marketLoading, true
	m.launch()
}

// At most two requests may be in flight: a replacement can start promptly
// while a cancelled transport is stopping, but rapid switching cannot create
// an unbounded set of workers. Only the latest queued source is started.
func (m *marketplaceState) launch() {
	if !m.pending || m.running >= marketMaxInFlight {
		return
	}
	fetch := m.fetch
	if m.source == 1 {
		fetch = m.official
	} else if m.source == 2 {
		fetch = m.installed
	}
	if fetch == nil {
		m.pending = false
		return
	}
	m.pending = false
	m.running++
	generation := m.generation
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	report := m.reportDiscarded
	results, wake := m.results, m.wake
	m.workers.Add(1)
	go func() {
		defer m.workers.Done()
		snapshot, err := fetch(ctx)
		reported := ctx.Err() != nil && err != nil && !errors.Is(err, context.Canceled) && report != nil
		if reported {
			report(err)
		}
		// There are at most marketMaxInFlight workers and the channel has the
		// same capacity, so a closed window never leaves a sender blocked.
		results <- marketResult{generation: generation, snapshot: snapshot, err: err, reported: reported}
		if wake != nil {
			wake()
		}
	}()
}

func (m *marketplaceState) chooseSource(source int) {
	if source == m.source || (source == 1 && m.official == nil) || (source == 2 && m.installed == nil) || source < 0 || source > 2 {
		return
	}
	m.close()
	m.source, m.selected, m.snapshot, m.index, m.err = source, "", marketplace.Snapshot{}, nil, nil
	m.start()
}
func (m *marketplaceState) close() {
	m.generation++
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.status = marketIdle
	m.pending = false
	m.search.invalidate()
}
func (m *marketplaceState) drain() {
	for {
		select {
		case result := <-m.results:
			m.running--
			if result.generation != m.generation {
				if result.err != nil && !result.reported && !errors.Is(result.err, context.Canceled) && m.reportDiscarded != nil {
					m.reportDiscarded(result.err)
				}
				// log-exempt: 用户取消：旧来源的正常或已取消结果不会再显示。
				m.launch()
				continue
			}
			if m.cancel != nil {
				m.cancel()
				m.cancel = nil
			}
			if errors.Is(result.err, context.Canceled) {
				m.status = marketIdle
				continue
			}
			m.apply(result.snapshot, result.err)
		default:
			return
		}
	}
}
func (m *marketplaceState) apply(snapshot marketplace.Snapshot, err error) {
	m.err = err
	if err != nil {
		m.status = marketFailed
		return
	}
	m.snapshot = snapshot
	m.status = marketReady
	m.search.setCatalog(snapshot.Index.Plugins)
	m.index = make(map[string]int, len(snapshot.Index.Plugins))
	for i, plugin := range snapshot.Index.Plugins {
		m.index[plugin.ID] = i
	}
	if _, ok := m.index[m.selected]; ok {
		return
	}
	m.selected = ""
	if len(snapshot.Index.Plugins) > 0 {
		m.selected = snapshot.Index.Plugins[0].ID
	}
}
