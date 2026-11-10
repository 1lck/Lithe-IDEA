package settingswindow

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/ui"
)

type marketStatus uint8

const (
	marketIdle marketStatus = iota
	marketLoading
	marketReady
	marketFailed
)

// marketResult is one finished fetch of an index.
type marketResult struct {
	snapshot marketplace.Snapshot
}

// marketplaceState is owned by the settings window. Each source's fetch is a page Effect
// keyed by the request's number: a new request, a switch of source or leaving the page
// stops declaring or re-keys the effect, which cancels the fetch, and a result that
// arrives after that is dropped. Only the window thread reads or writes the fields.
type marketplaceState struct {
	fetch           func(context.Context) (marketplace.Snapshot, error)
	official        func(context.Context) (marketplace.Snapshot, error)
	installed       func(context.Context) (marketplace.Snapshot, error)
	reportDiscarded func(error)
	source          int
	// effects are the fetches of the three sources, community, official and installed.
	effects [3]*ui.EffectState[marketResult, int]
	// request is the number of the fetch that is out or was last taken; active says one is
	// wanted, which is true from start until the page closes or the result is taken.
	request  int
	active   bool
	status   marketStatus
	snapshot marketplace.Snapshot
	selected string
	// index is rebuilt only when a new catalog arrives, not on every drag frame.
	index  map[string]int
	err    error
	search marketplaceSearch
	// list is the plugin list's state; its rows are the search's visible plugins, and
	// listFor the plugin the list last showed as chosen.
	list    ui.ListState
	listFor string
}

func newMarketplaceState(fetch func(context.Context) (marketplace.Snapshot, error)) *marketplaceState {
	m := &marketplaceState{fetch: fetch}
	for source := range m.effects {
		m.effects[source] = ui.NewEffect[marketResult, int](func(ctx context.Context) (marketResult, error) {
			run := m.fetchOf(source)
			if run == nil {
				return marketResult{}, errors.New("marketplace source is not available")
			}
			snapshot, err := run(ctx)
			// A fetch that failed after its context was canceled is discarded with the
			// rest of its result, so the failure is reported here or not at all.
			if ctx.Err() != nil && err != nil && !errors.Is(err, context.Canceled) && m.reportDiscarded != nil {
				m.reportDiscarded(err)
			}
			return marketResult{snapshot: snapshot}, err
		})
	}
	m.list.Key, m.list.Label = m.listKey, m.listLabel
	m.search.bind()
	return m
}

// listKey names the visible row i by the plugin it lists, so the row keeps its identity
// while a search reorders the list.
func (m *marketplaceState) listKey(i int) int {
	if visible := m.search.visible(); i >= 0 && i < len(visible) {
		return visible[i]
	}
	return i
}

// listLabel is the name of the plugin row i lists: what assistive technology reads and what
// typing the first letters of a name finds.
func (m *marketplaceState) listLabel(i int) string {
	if visible := m.search.visible(); i >= 0 && i < len(visible) {
		return m.snapshot.Index.Plugins[visible[i]].Name
	}
	return ""
}

func (m *marketplaceState) fetchOf(source int) func(context.Context) (marketplace.Snapshot, error) {
	switch source {
	case 1:
		return m.official
	case 2:
		return m.installed
	}
	return m.fetch
}

// start asks for the selected source's index.
func (m *marketplaceState) start() {
	if m.fetchOf(m.source) == nil || m.status == marketLoading {
		return
	}
	m.request++
	m.status, m.active = marketLoading, true
}

func (m *marketplaceState) chooseSource(source int) {
	if source == m.source || (source == 1 && m.official == nil) || (source == 2 && m.installed == nil) || source < 0 || source > 2 {
		return
	}
	m.close()
	m.source, m.selected, m.snapshot, m.index, m.err = source, "", marketplace.Snapshot{}, nil, nil
	m.start()
}

// close stops wanting the fetch, which cancels it, and forgets what the search found.
func (m *marketplaceState) close() {
	m.active = false
	m.status = marketIdle
	m.search.invalidate()
}

// take applies the finished fetch on the window thread at the start of a paint.
func (m *marketplaceState) take() {
	effect := m.effects[m.source]
	result, err, ok := effect.Take()
	if !ok || !m.active {
		return
	}
	m.active = false
	if errors.Is(err, context.Canceled) {
		m.status = marketIdle
		return
	}
	m.apply(result.snapshot, err)
}

// declare keeps the wanted fetch alive in the paint.
func (m *marketplaceState) declare(c ui.C) {
	if m.active {
		ui.Effect(c, m.effects[m.source], m.request)
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
