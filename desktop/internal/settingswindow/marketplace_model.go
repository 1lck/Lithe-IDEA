package settingswindow

import (
	"context"
	"errors"

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
}

// marketplaceState is owned by the settings window. Only the result channel is used
// by the background fetch; closing or leaving the page cancels and invalidates it.
type marketplaceState struct {
	fetch      func(context.Context) (marketplace.Snapshot, error)
	wake       func()
	results    chan marketResult
	cancel     context.CancelFunc
	generation uint64
	status     marketStatus
	snapshot   marketplace.Snapshot
	selected   string
	// index is rebuilt only when a new catalog arrives, not on every drag frame.
	index map[string]int
	err   error
}

func newMarketplaceState(fetch func(context.Context) (marketplace.Snapshot, error), wake func()) *marketplaceState {
	return &marketplaceState{fetch: fetch, wake: wake, results: make(chan marketResult, 1)}
}
func (m *marketplaceState) start() {
	if m.fetch == nil || m.status == marketLoading {
		return
	}
	m.generation++
	generation := m.generation
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.status = marketLoading
	go func() {
		snapshot, err := m.fetch(ctx)
		select {
		case m.results <- marketResult{generation: generation, snapshot: snapshot, err: err}:
			if m.wake != nil {
				m.wake()
			}
		case <-ctx.Done():
		}
	}()
}
func (m *marketplaceState) close() {
	m.generation++
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.status = marketIdle
}
func (m *marketplaceState) drain() {
	for {
		select {
		case result := <-m.results:
			if result.generation != m.generation {
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
