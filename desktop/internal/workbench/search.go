package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// The query and mask fields are named by the application so the window can
// move the keyboard to the query (Find in Files) and tests can address them.
var (
	searchQueryID = tree.ID(shellPage, "project-search-query")
	searchMaskID  = tree.ID(shellPage, "project-search-mask")
)

const (
	searchResultHeight = 52
	searchMaxResults   = 200
	searchDebounce     = 250 * time.Millisecond
	searchTimeout      = 30 * time.Second
	searchEventLimit   = 4096
	searchUpdateLimit  = 512
)

type searchQuery struct {
	text, mask                   string
	matchCase, wholeWords, regex bool
}

// searchView contains only controls and options; results belong to a project.
type searchView struct {
	query, mask                                      ui.Field
	optionsOpen, matchCase, wholeWords, regex, focus bool
	// list is the result list's selection and scroll; page is the panel.
	list ui.ListState
	page *ui.Page
	// delay is overridden in deterministic tests; negative means the normal delay.
	delay time.Duration
}

func (v *searchView) reset() {
	v.query.SetText("")
	v.mask.SetText("")
	v.optionsOpen, v.matchCase, v.wholeWords, v.regex, v.focus = false, false, false, false, false
	v.list = ui.ListState{}
}

type projectSearch struct {
	want             searchQuery
	generation       uint64
	cancel           context.CancelFunc
	running, loading bool
	indexUsed        bool
	matches          []core.WorkspaceSearchMatch
	failed           bool
	watch            *documentWatch
	watchAttached    bool
	watchReady       bool
	watchAvailable   bool
	fullResync       bool
	pending          []string
	done             <-chan struct{}
}

func (a *App) cancelProjectSearch(p *project) {
	p.search.generation++
	p.search.want = searchQuery{}
	p.search.loading = false
	a.searchView.optionsOpen = false
	if p.search.cancel != nil {
		p.search.cancel()
	}
	p.search.watchAttached = false
	if !p.everywhere.watchAttached && !p.tree.recursiveWatch && p.search.watch != nil {
		p.search.watch.close()
		p.search.watch = nil
		p.search.watchReady, p.search.watchAvailable = false, false
	}
	p.search.pending = nil
	p.search.fullResync = true
}

// Register away from the window thread: Linux may need to walk the tree and
// create one OS registration for every directory.
func (a *App) startProjectSearchWatch(p *project) {
	s := &p.search
	if s.watch != nil {
		return
	}
	slot := &documentWatch{}
	s.watch = slot
	s.watchReady, s.watchAvailable = false, false
	if p.everywhere.watchAttached {
		p.everywhere.watchReady, p.everywhere.watchAvailable = false, false
	}
	a.tasks.running.Add(1)
	wake := func() { a.post(func(a *App) { a.drainProjectSearchWatch(p, slot) }) }
	go func() {
		defer a.tasks.running.Done()
		watch, err := app.WatchTree(p.root, nil, wake)
		var observed documentDirectoryWatch
		if watch != nil {
			observed = watch
		}
		slot.finish(observed, err)
		wake()
	}()
}

func (a *App) drainProjectSearchWatch(p *project, slot *documentWatch) {
	s := &p.search
	if a.project != p || s.watch != slot {
		return
	}
	watch, ready, err := slot.state()
	if ready {
		s.watchReady, s.watchAvailable, s.fullResync = true, watch != nil, true
		if err != nil && s.watchAttached {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_watch", err))
			a.notify(i18n.Shared(a.language(), "desktop.search.watchUnavailable"))
		}
	}
	changed := false
	var events app.DirectoryChanges
	if watch != nil {
		events = watch.Changes(nil)
		if events.Resync {
			operation := "workspace_search_incremental_update"
			if !s.watchAttached && !p.everywhere.watchAttached && p.tree.recursiveWatch {
				operation = "project_tree_watch"
			}
			a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": operation, "reason": "watch_events_lost"})
			// The root may have been replaced, so install a fresh watch before
			// rebuilding. The new watch covers changes during the rebuild.
			slot.close()
			s.watch = nil
			s.pending = nil
			s.fullResync = true
			a.startProjectSearchWatch(p)
			changed = true
		} else if len(events.Names) > 0 {
			if len(s.pending)+len(events.Names) > searchEventLimit {
				a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "workspace_search_incremental_update", "reason": "event_limit_exceeded"})
				s.pending = nil
				s.fullResync = true
			} else if !s.fullResync {
				s.pending = append(s.pending, events.Names...)
			}
			changed = true
		}
	}
	if p.everywhere.watchAttached {
		a.applyEverywhereWatch(p, ready, watch != nil, err, events)
	}
	if p.tree.recursiveWatch {
		a.applyTreeRecursiveWatch(p, ready, watch != nil, err, events)
	}
	if changed {
		s.generation++
		if s.cancel != nil {
			s.cancel()
		}
		if strings.TrimSpace(s.want.text) != "" {
			s.loading = true
		}
	}
	if s.watchReady && !s.running && strings.TrimSpace(s.want.text) != "" {
		a.runProjectSearch(p)
	}
}

// updateProjectSearch keeps at most one kernel operation running. Each newer
// request cancels the old one; a completed stale operation starts its successor.
func (a *App) updateProjectSearch(p *project, query searchQuery) {
	s := &p.search
	if s.want == query {
		return
	}
	s.want = query
	s.generation++
	s.matches, s.failed = nil, false
	a.searchView.list.ScrollTo(0, ui.ListStart)
	if s.cancel != nil {
		s.cancel()
	}
	if strings.TrimSpace(query.text) == "" {
		s.loading = false
		return
	}
	s.loading = true
	wasAttached := s.watchAttached
	s.watchAttached = true
	if !wasAttached && s.watchReady && !s.watchAvailable && s.watch != nil {
		_, _, err := s.watch.state()
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_watch", err))
		}
		a.notify(i18n.Shared(a.language(), "desktop.search.watchUnavailable"))
	}
	if s.watch == nil {
		a.startProjectSearchWatch(p)
	}
	if !s.running && s.watchReady {
		a.runProjectSearch(p)
	}
}

func (a *App) refreshProjectSearch(p *project) {
	query := p.search.want
	p.search.fullResync = true
	p.search.want = searchQuery{}
	a.updateProjectSearch(p, query)
}

func (a *App) runProjectSearch(p *project) {
	s := &p.search
	if s.running || !s.watchReady || strings.TrimSpace(s.want.text) == "" {
		return
	}
	query, generation := s.want, s.generation
	full, paths := s.fullResync || !s.watchAvailable, s.pending
	s.fullResync, s.pending = false, nil
	s.indexUsed = true
	ctx, cancel := context.WithCancel(p.ctx)
	s.cancel, s.running = cancel, true
	finished := make(chan struct{})
	s.done = finished
	delay := a.searchView.delay
	if delay < 0 {
		delay = searchDebounce
	}
	kernel, root := a.kernel, p.root
	a.background(p, 0, func(context.Context) func(*App) {
		defer close(finished)
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				return func(a *App) { a.finishProjectSearch(p, generation, nil, ctx.Err(), full || len(paths) > 0) }
			}
		}
		operation, done := context.WithTimeout(ctx, searchTimeout)
		defer done()
		err := synchronizeSearchIndex(operation, kernel, root, full, paths)
		var matches []core.WorkspaceSearchMatch
		if err == nil {
			matches, err = kernel.SearchWorkspace(operation, core.WorkspaceSearchRequest{Root: root, Query: query.text, FileMask: query.mask, CaseSensitive: query.matchCase, WholeWords: query.wholeWords, RegularExpression: query.regex, MaxResults: searchMaxResults})
		}
		return func(a *App) { a.finishProjectSearch(p, generation, matches, err, full || len(paths) > 0) }
	})
}

// synchronizeSearchIndex delegates visibility and incremental updates to Core.
// A lost or excessively large event batch requires a complete rebuild instead.
func synchronizeSearchIndex(ctx context.Context, kernel Kernel, root string, full bool, paths []string) error {
	if full {
		return kernel.InvalidateWorkspaceSearch(ctx, root)
	}
	if len(paths) == 0 {
		return nil
	}
	filtered, err := kernel.FilterWorkspaceChanges(ctx, paths)
	if err != nil {
		return err
	}
	if len(filtered) > searchUpdateLimit {
		return kernel.InvalidateWorkspaceSearch(ctx, root)
	}
	if len(filtered) == 0 {
		return nil
	}
	return kernel.UpdateWorkspaceSearch(ctx, root, filtered)
}

// releaseProjectSearch drops Core's index after the project closes so switching
// among projects does not retain every workspace inventory for the whole session.
func (a *App) releaseProjectSearch(p *project) {
	if p.search.watch != nil {
		p.search.watch.close()
		p.search.watch = nil
	}
	if !p.search.indexUsed {
		return
	}
	kernel, root, sink, finished, everywhereFinished := a.kernel, p.root, a.logSink, p.search.done, p.everywhere.done
	a.background(nil, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var err error
		for _, job := range []<-chan struct{}{finished, everywhereFinished} {
			if job == nil || err != nil {
				continue
			}
			select {
			case <-job:
			case <-ctx.Done():
				err = ctx.Err()
			}
		}
		if err == nil {
			err = kernel.InvalidateWorkspaceSearch(ctx, root)
		}
		if err != nil && !errors.Is(err, context.Canceled) && sink != nil {
			sink.Emit(operationFailedLevel, operationFailedEvent, "", operationFailedFields("workspace_search_cleanup", err))
		}
		return nil
	})
}

func (a *App) finishProjectSearch(p *project, generation uint64, matches []core.WorkspaceSearchMatch, err error, indexChanged bool) {
	s := &p.search
	s.running, s.cancel = false, nil
	if err != nil && indexChanged {
		s.fullResync = true
	}
	if generation != s.generation {
		if err != nil && !errors.Is(err, context.Canceled) {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search", err))
		}
		if s.watchReady && strings.TrimSpace(s.want.text) != "" {
			a.runProjectSearch(p)
		}
		return
	}
	s.loading = false
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		s.failed = true
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search", err))
		return
	}
	s.matches = matches
}

func (a *App) openSearchResult(p *project, result core.WorkspaceSearchMatch) {
	// Defend the adapter boundary even though Core returns workspace-relative paths.
	relative := filepath.FromSlash(result.Path)
	if relative == "" || filepath.IsAbs(relative) {
		a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "workspace_search", "reason": "invalid_result_path"})
		return
	}
	path := filepath.Join(p.root, relative)
	rel, err := filepath.Rel(p.root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "workspace_search", "reason": "invalid_result_path"})
		return
	}
	line := 0
	if result.Line != nil {
		line = *result.Line
	}
	a.openFileAt(p, path, line)
}
