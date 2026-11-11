package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// everywhereQueryID names the query field so the panel can give it the keyboard
// and the host can tell when a key is typed in it.
var everywhereQueryID = tree.ID(shellPage, "everywhere-query")

// everywhereScopeActions is the index of the Actions tab, which lists commands
// rather than searching the project.
const everywhereScopeActions = 4

// everywhereScopeCount is the number of tabs, everywhereKinds the kinds of names the
// All tab lists (each can be filtered out).
const everywhereScopeCount = 6

var everywhereKinds = []string{"file", "type", "symbol"}

const (
	everywherePageSize   = 50
	everywhereMaxResults = 500
	everywhereDebounce   = 180 * time.Millisecond
	everywhereFileHeight = 24
	everywhereTextHeight = 40
)

type everywhereView struct {
	query       ui.Field
	open, focus bool
	scope       int
	list        ui.ListState
	// scrolledTo is the selected match the list last scrolled into view, so only a selection
	// that moved scrolls the list.
	scrolledTo int
	// actionList, actionSelected and actionCount are the Actions tab's list (commands.go).
	actionList     ui.ListState
	actionSelected int
	actionCount    int
	// Tests can request zero delay without changing production timing.
	delay time.Duration
	// preview shows the selected result's file below the list; split is the list's
	// height above it and source the read-only view.
	preview bool
	split   ui.SplitterState
	source  sourcePreview
	// filterOpen shows the tab's filter; hiddenKinds are the kinds the All tab leaves
	// out, and the three switches are the Text tab's options.
	filterOpen                   bool
	hiddenKinds                  map[string]bool
	matchCase, wholeWords, regex bool
	// gesture is Core's double-Shift state (keymap.modifierGestureStep), opaque here.
	gesture json.RawMessage
}

// everywhereOptions is what besides the query and the tab decides a search.
type everywhereOptions struct {
	kinds                        string
	matchCase, wholeWords, regex bool
}

// effectiveScope is the tab the query is for: a query that starts with "/" lists
// commands whatever tab is selected.
func (v *everywhereView) effectiveScope() int {
	if strings.HasPrefix(v.query.Text(), "/") {
		return everywhereScopeActions
	}
	return v.scope
}

// actionQuery is the text the Actions list matches: the query without the "/" that
// asked for commands.
func (v *everywhereView) actionQuery() string {
	return strings.TrimPrefix(v.query.Text(), "/")
}

// resultKinds are the kinds of match a tab asks Core for.
func (v *everywhereView) resultKinds(scope int) []string {
	switch scope {
	case 1:
		return []string{"type"}
	case 2:
		return []string{"file"}
	case 3:
		return []string{"symbol"}
	case 5:
		return []string{"content"}
	}
	kinds := make([]string, 0, len(everywhereKinds))
	for _, kind := range everywhereKinds {
		if !v.hiddenKinds[kind] {
			kinds = append(kinds, kind)
		}
	}
	return kinds
}

// options is the search options of a tab.
func (v *everywhereView) options(scope int) everywhereOptions {
	o := everywhereOptions{kinds: strings.Join(v.resultKinds(scope), ",")}
	if scope == 5 {
		o.matchCase, o.wholeWords, o.regex = v.matchCase, v.wholeWords, v.regex
	}
	return o
}

// filtered reports whether the current tab's filter differs from its default.
func (v *everywhereView) filtered() bool {
	if v.scope == 5 {
		return v.matchCase || v.wholeWords || v.regex
	}
	for _, kind := range everywhereKinds {
		if v.hiddenKinds[kind] {
			return true
		}
	}
	return false
}

type everywhereSearch struct {
	query                    string
	scope                    int
	options                  everywhereOptions
	generation               uint64
	cancel                   context.CancelFunc
	running, loading, failed bool
	request                  core.EverywhereSearchRequest
	matches                  []core.WorkspaceSearchMatch
	cursor                   *string
	selected                 int
	done                     <-chan struct{}
	watchAttached            bool
	watchReady               bool
	watchAvailable           bool
	fullResync               bool
	pending                  []string
}

func (a *App) openEverywhere(p *project) {
	if a.everywhereView.open {
		a.focusEverywhere(p)
		return
	}
	a.everywhereView.open = true
	a.everywhereView.scope = 0
	a.everywhereView.query.SetText("")
	p.everywhere.selected = 0
	a.focusEverywhere(p)
}

// Apply focus after the opening pointer event has finished assigning focus to
// its toolbar button; otherwise that assignment overwrites the field request.
func (a *App) focusEverywhere(p *project) {
	a.post(func(a *App) {
		if a.project == p && a.everywhereView.open {
			a.everywhereView.focus = true
		}
	})
}

func (a *App) closeEverywhere(p *project) {
	if p == nil {
		return
	}
	s := &p.everywhere
	s.generation++
	s.query, s.loading, s.matches, s.cursor = "", false, nil, nil
	if s.cancel != nil {
		s.cancel()
	}
	s.watchAttached = false
	if !p.search.watchAttached && !p.tree.recursiveWatch && p.search.watch != nil {
		p.search.watch.close()
		p.search.watch = nil
		p.search.watchReady, p.search.watchAvailable = false, false
	}
	s.watchReady, s.watchAvailable, s.fullResync = false, false, true
	s.pending = nil
	a.everywhereView.open, a.everywhereView.focus = false, false
	a.everywhereView.filterOpen = false
	a.everywhereView.source.close()
	a.everywhereView.query.SetText("")
}

func (a *App) updateEverywhere(p *project, query string, scope int) {
	v, s := &a.everywhereView, &p.everywhere
	options := v.options(scope)
	if s.query == query && s.scope == scope && s.options == options {
		return
	}
	s.query, s.scope, s.options = query, scope, options
	s.generation++
	s.matches, s.cursor, s.failed, s.selected = nil, nil, false, 0
	v.list.ScrollTo(0, ui.ListStart)
	if s.cancel != nil {
		s.cancel()
	}
	a.startEverywhereSymbols(p, query, scope)
	kinds := v.resultKinds(scope)
	if strings.TrimSpace(query) == "" || scope == everywhereScopeActions || len(kinds) == 0 {
		s.loading = false
		return
	}
	openPaths := make([]string, 0, len(p.docs.list))
	for _, doc := range p.docs.list {
		if relative, ok := projectRelativePath(p.root, doc.path); ok {
			openPaths = append(openPaths, relative)
		}
	}
	s.request = core.EverywhereSearchRequest{Root: p.root, Query: query, PageSize: everywherePageSize, ResultKinds: kinds,
		IncludeGeneratedFileNames: scope != 5, Context: &core.EverywhereSearchContext{OpenPaths: openPaths},
		CaseSensitive: options.matchCase, WholeWords: options.wholeWords, RegularExpression: options.regex,
		IncludeContentRanges: scope == 5}
	s.loading = true
	if !s.watchAttached {
		a.startEverywhereWatch(p)
	}
	if !s.running && s.watchReady {
		a.runEverywhere(p, false)
	}
}

func (a *App) startEverywhereWatch(p *project) {
	s := &p.everywhere
	if s.watchAttached {
		return
	}
	s.watchAttached = true
	if p.search.watch == nil {
		a.startProjectSearchWatch(p)
	} else if p.search.watchReady {
		s.watchReady, s.watchAvailable, s.fullResync = true, p.search.watchAvailable, true
		if !s.watchAvailable {
			_, _, err := p.search.watch.state()
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere_watch", err))
			}
			a.notifyError(i18n.Shared(a.language(), "desktop.everywhere.watchUnavailable"))
		}
	}
}

// The sidebar and popup share one native tree watch. Each keeps its own
// pending batch and cancellation generation while Core owns the index.
func (a *App) applyEverywhereWatch(p *project, ready, available bool, err error, events app.DirectoryChanges) {
	s := &p.everywhere
	if !s.watchAttached || !a.everywhereView.open {
		return
	}
	if ready {
		s.watchReady, s.watchAvailable, s.fullResync = true, available, true
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere_watch", err))
			a.notifyError(i18n.Shared(a.language(), "desktop.everywhere.watchUnavailable"))
		}
	}
	changed := false
	if events.Resync {
		s.watchReady, s.watchAvailable, s.fullResync = false, false, true
		s.pending = nil
		changed = true
	} else if len(events.Names) > 0 {
		if len(s.pending)+len(events.Names) > searchEventLimit {
			a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "workspace_search_incremental_update", "reason": "event_limit_exceeded"})
			s.pending, s.fullResync = nil, true
		} else if !s.fullResync {
			s.pending = append(s.pending, events.Names...)
		}
		changed = true
	}
	if changed {
		s.generation++
		if s.cancel != nil {
			s.cancel()
		}
		if strings.TrimSpace(s.query) != "" {
			s.loading = true
		}
	}
	if s.watchReady && !s.running && strings.TrimSpace(s.query) != "" {
		a.runEverywhere(p, false)
	}
}

func (a *App) runEverywhere(p *project, next bool) {
	s := &p.everywhere
	if s.running || !s.watchReady || !a.everywhereView.open || strings.TrimSpace(s.query) == "" {
		return
	}
	request, generation := s.request, s.generation
	if next {
		if s.cursor == nil || len(s.matches) >= everywhereMaxResults {
			return
		}
		request.Cursor = s.cursor
	}
	full, paths := false, []string(nil)
	if !next {
		full, paths = s.fullResync || !s.watchAvailable, s.pending
		s.fullResync, s.pending = false, nil
	}
	p.search.indexUsed = true
	ctx, cancel := context.WithCancel(p.ctx)
	s.cancel, s.running, s.loading = cancel, true, true
	s.failed = false
	finished := make(chan struct{})
	s.done = finished
	delay := a.everywhereView.delay
	if delay < 0 {
		delay = everywhereDebounce
	}
	kernel := a.kernel
	a.background(p, 0, func(context.Context) func(*App) {
		defer close(finished)
		defer cancel()
		if !next && delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				return func(a *App) {
					a.finishEverywhere(p, generation, next, core.EverywhereSearchPage{}, ctx.Err(), full || len(paths) > 0)
				}
			}
		}
		operation, done := context.WithTimeout(ctx, searchTimeout)
		defer done()
		var err error
		if !next {
			err = synchronizeSearchIndex(operation, kernel, p.root, full, paths)
		}
		var page core.EverywhereSearchPage
		if err == nil {
			page, err = kernel.SearchEverywherePage(operation, request)
		}
		return func(a *App) { a.finishEverywhere(p, generation, next, page, err, full || len(paths) > 0) }
	})
}

func (a *App) finishEverywhere(p *project, generation uint64, next bool, page core.EverywhereSearchPage, err error, indexChanged bool) {
	s := &p.everywhere
	s.running, s.cancel = false, nil
	if err != nil && indexChanged {
		s.fullResync = true
	}
	if generation != s.generation {
		if err != nil && !errors.Is(err, context.Canceled) {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere", err))
		}
		if s.watchReady && a.everywhereView.open && strings.TrimSpace(s.query) != "" {
			a.runEverywhere(p, false)
		}
		return
	}
	// Symbols from the language servers are rebuilt with the Core list on every answer.
	a.everywhereStripSymbols(p)
	defer a.everywhereSymbolsMerge(p)
	s.loading = false
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			s.failed = true
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere", err))
		}
		return
	}
	sortEverywherePage(page.Matches)
	if next {
		type identity struct {
			kind, path, symbol string
			line               int
		}
		key := func(match core.WorkspaceSearchMatch) identity {
			id := identity{kind: match.Kind, path: match.Path}
			if match.Line != nil {
				id.line = *match.Line
			}
			if match.SymbolName != nil {
				id.symbol = *match.SymbolName
			}
			return id
		}
		seen := make(map[identity]struct{}, len(s.matches)+len(page.Matches))
		for _, match := range s.matches {
			seen[key(match)] = struct{}{}
		}
		before := len(s.matches)
		for _, match := range page.Matches {
			id := key(match)
			if _, ok := seen[id]; !ok {
				seen[id] = struct{}{}
				s.matches = append(s.matches, match)
			}
		}
		if page.NextCursor != nil && ((s.cursor != nil && *page.NextCursor == *s.cursor) || len(s.matches) == before) {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere_page", errors.New("search page did not advance")))
			s.failed, s.cursor = true, nil
			return
		}
	} else {
		s.matches = page.Matches
	}
	if len(s.matches) > everywhereMaxResults {
		s.matches = s.matches[:everywhereMaxResults]
	}
	s.cursor = page.NextCursor
}

// sortEverywherePage orders one page by Core's matching degree, highest first. Equal
// degrees keep Core's order, so rows do not jump while the user types; earlier pages
// stay where they are.
func sortEverywherePage(matches []core.WorkspaceSearchMatch) {
	degree := func(m core.WorkspaceSearchMatch) int {
		if m.MatchingDegree == nil {
			return 0
		}
		return *m.MatchingDegree
	}
	sort.SliceStable(matches, func(i, j int) bool { return degree(matches[i]) > degree(matches[j]) })
}
