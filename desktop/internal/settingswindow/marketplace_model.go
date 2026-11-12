package settingswindow

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
	// failures are the sources an aggregate could not read; the others still show.
	failures []marketFailure
}

// marketFailure is one source the aggregate could not read, named by its index URL or label.
type marketFailure struct {
	name string
	err  error
}

// marketRun is one source's fetch as the page's effect runs it.
type marketRun func(context.Context) (marketResult, error)

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
	// custom are the index URLs the user added, in the order they were added; customFetch reads one.
	custom      []string
	customFetch func(context.Context, string) (marketplace.Snapshot, error)
	// failures are the sources the last aggregate could not read.
	failures []marketFailure
	// detailTab is the page of the selected plugin's detail that is open: one of the detail*
	// constants of marketplace_view.go.
	detailTab int
	// effects are the fetches of the sources: community, official, installed, the custom ones and
	// the aggregate of all of them last. runs are what they run, captured when they were built.
	effects []*ui.EffectState[marketResult, int]
	runs    []marketRun
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
	m.buildEffects()
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

// buildEffects makes the effects of the current sources. It runs when the page is made and when
// the custom sources change; a source's effect is keyed by its index, which the list fixes.
func (m *marketplaceState) buildEffects() {
	m.runs = m.sourceRuns()
	m.effects = make([]*ui.EffectState[marketResult, int], len(m.runs))
	for index := range m.runs {
		run := m.runs[index]
		m.effects[index] = ui.NewEffect[marketResult, int](func(ctx context.Context) (marketResult, error) {
			result, err := run(ctx)
			// A fetch that failed after its context was canceled is discarded with the
			// rest of its result, so the failure is reported here or not at all.
			if ctx.Err() != nil && err != nil && !errors.Is(err, context.Canceled) && m.reportDiscarded != nil {
				m.reportDiscarded(err)
			}
			return result, err
		})
	}
}

// sourceRuns are the runs of every source in index order: the three fixed ones, the custom ones,
// then the aggregate of every source that can be read.
func (m *marketplaceState) sourceRuns() []marketRun {
	single := func(fetch func(context.Context) (marketplace.Snapshot, error)) marketRun {
		if fetch == nil {
			return func(context.Context) (marketResult, error) {
				return marketResult{}, errors.New("marketplace source is not available")
			}
		}
		return func(ctx context.Context) (marketResult, error) {
			snapshot, err := fetch(ctx)
			return marketResult{snapshot: snapshot}, err
		}
	}
	runs := []marketRun{single(m.fetch), single(m.official), single(m.installed)}
	// The aggregate reads community first, so its plugins win a duplicate, then official, then the
	// custom sources. An empty name stands for community, which the page labels itself.
	named := []namedRun{{name: "", run: single(m.fetch)}}
	if m.official != nil {
		named = append(named, namedRun{name: "official", run: single(m.official)})
	}
	for _, url := range m.custom {
		run := single(nil)
		if m.customFetch != nil {
			fetch, index := m.customFetch, url
			run = single(func(ctx context.Context) (marketplace.Snapshot, error) { return fetch(ctx, index) })
		}
		runs = append(runs, run)
		named = append(named, namedRun{name: url, run: run})
	}
	runs = append(runs, aggregateRun(named))
	return runs
}

// namedRun is a source an aggregate reads, with the name its failure is reported under.
type namedRun struct {
	name string
	run  marketRun
}

// aggregateRun reads every source and merges their plugins by ID, the first source in the list
// winning a duplicate. A source that fails is reported on its own and the others still show; the
// aggregate fails only when none of them could be read.
func aggregateRun(sources []namedRun) marketRun {
	return func(ctx context.Context) (marketResult, error) {
		seen := map[string]bool{}
		var plugins []core.MarketplacePlugin
		var failures []marketFailure
		read := 0
		for _, source := range sources {
			result, err := source.run(ctx)
			if err != nil {
				failures = append(failures, marketFailure{name: source.name, err: err})
				continue
			}
			read++
			for _, plugin := range result.snapshot.Index.Plugins {
				if !seen[plugin.ID] {
					seen[plugin.ID] = true
					plugins = append(plugins, plugin)
				}
			}
		}
		if read == 0 && len(failures) > 0 {
			return marketResult{failures: failures}, failures[0].err
		}
		return marketResult{snapshot: marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, failures: failures}, nil
	}
}

// aggregateSource is the index of the aggregate of every source, after the custom ones.
func (m *marketplaceState) aggregateSource() int { return marketFixedSources + len(m.custom) }

// sourceCount is how many sources the page offers, the aggregate included.
func (m *marketplaceState) sourceCount() int { return m.aggregateSource() + 1 }

// setCustom replaces the custom sources and rebuilds their effects. The one the user had chosen
// stays chosen when it still exists; otherwise the page starts again from community.
func (m *marketplaceState) setCustom(urls []string) {
	m.close()
	m.custom = append([]string(nil), urls...)
	m.buildEffects()
	if m.source >= m.sourceCount() {
		m.source = 0
	}
	m.selected, m.snapshot, m.index, m.err = "", marketplace.Snapshot{}, nil, nil
}

// marketFixedSources is the number of sources that are not user-added: community, official and installed.
const marketFixedSources = 3

// fetchOf reports whether a source can be read, through the fetch the source reads from.
func (m *marketplaceState) fetchOf(source int) func(context.Context) (marketplace.Snapshot, error) {
	switch {
	case source == 1:
		return m.official
	case source == 2:
		return m.installed
	case source >= marketFixedSources && source < m.aggregateSource():
		if m.customFetch == nil {
			return nil
		}
		return func(ctx context.Context) (marketplace.Snapshot, error) {
			return m.customFetch(ctx, m.custom[source-marketFixedSources])
		}
	case source == m.aggregateSource():
		return m.fetch
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
	if source == m.source || (source == 1 && m.official == nil) || (source == 2 && m.installed == nil) || source < 0 || source >= m.sourceCount() {
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
	m.failures = result.failures
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
