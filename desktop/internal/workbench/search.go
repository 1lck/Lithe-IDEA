package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	searchQueryID     = tree.ID(shellPage, "project-search-query")
	searchMaskID      = tree.ID(shellPage, "project-search-mask")
	searchClearID     = tree.ID(shellPage, "project-search-clear")
	searchClearMaskID = tree.ID(shellPage, "project-search-clear-mask")
	searchOptionsID   = tree.ID(shellPage, "project-search-options")
	searchRefreshID   = tree.ID(shellPage, "project-search-refresh")
	searchDismissID   = tree.ID(shellPage, "project-search-dismiss-options")
	searchOptionIDs   = tree.Sub(shellPage, tree.Name("project-search-option"))
	searchListID      = tree.ID(shellPage, "project-search-results")
	searchRows        = tree.Sub(shellPage, tree.Name("project-search-result"))
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
	optionButton                                     ui.Box
	rowFocus                                         gfx.ID
	// delay is overridden in deterministic tests; negative means the normal delay.
	delay time.Duration
}

func (v *searchView) reset() {
	v.query.SetText("")
	v.mask.SetText("")
	v.optionsOpen, v.matchCase, v.wholeWords, v.regex, v.focus = false, false, false, false, false
	v.rowFocus = gfx.ID{}
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
	a.searchView.rowFocus = gfx.ID{}
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
	a.view.ScrollState(searchListID).ScrollTo(0)
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

func (a *App) drawSearchRefresh(f *ui.Frame, p *project) {
	disabled := strings.TrimSpace(p.search.want.text) == ""
	button := f.Row().Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(searchRefreshID, i18n.Shared(a.language(), "ui.refresh"), gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Disabled: disabled}).
		Hover(ui.Look{}.Background(a.colors.Hover))
	button.Children(func() { f.Icon(icons.RefreshCw).Size(shellIconSize, shellIconSize).Color(a.colors.Subtle) })
	if !disabled && button.Clicked() {
		a.performed("workspace.search.refresh", surfaceButton)
		a.refreshProjectSearch(p)
	}
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

func (a *App) drawProjectSearch(f *ui.Frame, p *project) {
	v := &a.searchView
	query := searchQuery{text: v.query.Text(), mask: v.mask.Text(), matchCase: v.matchCase, wholeWords: v.wholeWords, regex: v.regex}
	a.updateProjectSearch(p, query)
	if v.focus {
		f.Canvas().RequestFocus(searchQueryID)
		v.focus = false
	}
	if !v.rowFocus.IsZero() {
		f.Canvas().RequestFocus(v.rowFocus)
		v.rowFocus = gfx.ID{}
	}
	f.Column().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		f.Row().FillWidth().PadSides(3, 10, 6, 10).Children(func() {
			var field ui.Box
			frame := f.Row().FillWidth().Height(30).PadX(7).Gap(7).Items(ui.Center).
				Border(1, a.theme.Input).Radius(a.theme.Metrics.RadiusControl).Focused(ui.Look{}.Border(a.theme.Primary))
			frame.Children(func() {
				f.Icon(icons.Search).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
				field = f.FieldBase(&v.query, searchQueryID, i18n.Shared(a.language(), "native.searchFilesAndContents"), i18n.Shared(a.language(), "native.searchFilesAndContents")).Grow(1).MinWidth(0).Height(28).FontSize(13).Color(a.colors.Text)
				if v.query.Text() != "" {
					if a.drawSearchClear(f, searchClearID) {
						v.query.SetText("")
						f.Canvas().RequestFocus(searchQueryID)
						f.Canvas().RequestFrame()
					}
				}
				button := f.Row().Size(22, 22).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).HitWith(searchOptionsID, i18n.Shared(a.language(), "native.searchOptions"), gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: v.optionsOpen}).Hover(ui.Look{}.Background(a.colors.Hover))
				v.optionButton = button
				button.Children(func() { f.Icon(icons.Settings).Size(16, 16).Color(a.colors.Subtle) })
				if button.Clicked() {
					v.optionsOpen = !v.optionsOpen
				}
			})
			frame.StateFrom(field)
		})
		f.Row().FillWidth().PadX(10).PadSides(0, 10, 10, 10).Children(func() {
			var field ui.Box
			frame := f.Row().FillWidth().Height(30).PadX(7).Gap(7).Items(ui.Center).
				Border(1, a.theme.Input).Radius(a.theme.Metrics.RadiusControl).Focused(ui.Look{}.Border(a.theme.Primary))
			frame.Children(func() {
				f.Icon(icons.Search).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
				field = f.FieldBase(&v.mask, searchMaskID, i18n.Shared(a.language(), "native.fileMask"), i18n.Shared(a.language(), "desktop.search.fileMaskPlaceholder")).Grow(1).MinWidth(0).Height(28).FontSize(13).Color(a.colors.Text)
				if v.mask.Text() != "" && a.drawSearchClear(f, searchClearMaskID) {
					v.mask.SetText("")
					f.Canvas().RequestFocus(searchMaskID)
					f.Canvas().RequestFrame()
				}
			})
			frame.StateFrom(field)
		})
		f.Row().FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		switch {
		case strings.TrimSpace(query.text) == "":
			f.Column().Fill().Center().Gap(9).Children(func() {
				f.Icon(icons.Search).Size(28, 28).Color(a.colors.Subtle)
				f.Text(i18n.Shared(a.language(), "native.searchAcrossTheProject")).Color(a.colors.Subtle)
			})
		case p.search.loading:
			f.Column().Fill().Center().Children(func() { f.Text(i18n.Shared(a.language(), "quickOpen.searching")).Color(a.colors.Subtle) })
		case p.search.failed:
			f.Column().Fill().Center().Children(func() { f.Text(i18n.Shared(a.language(), "search.failed")).Color(a.theme.Danger) })
		case len(p.search.matches) == 0:
			f.Column().Fill().Center().Children(func() { f.Text(i18n.Shared(a.language(), "native.noMatches")).Color(a.colors.Subtle) })
		default:
			a.drawSearchResults(f, p)
		}
	})
	if v.optionsOpen {
		a.drawSearchOptions(f)
	}
}

func (a *App) drawSearchClear(f *ui.Frame, id gfx.ID) bool {
	button := f.Row().Size(18, 18).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, i18n.Shared(a.language(), "native.clearSearch"), gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover))
	button.Children(func() { f.Icon(icons.X).Size(14, 14).Color(a.colors.Subtle) })
	if !button.Clicked() {
		return false
	}
	a.performed("workspace.search.clear", surfaceButton)
	return true
}

func (a *App) drawSearchOptions(f *ui.Frame) {
	v := &a.searchView
	dismiss := f.Popup().At(0, 0).Fill().HitWith(searchDismissID, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true}).Clicked()
	f.Popup().BelowBox(v.optionButton, 4, ui.End).Width(210).Pad(8).Gap(6).Background(a.theme.Popover).Border(1, a.theme.Border).Radius(a.theme.Metrics.RadiusPopup()).Children(func() {
		if f.Checkbox(searchOptionIDs.At(0), v.matchCase).Label(i18n.Shared(a.language(), "native.matchCase")).Clicked() {
			a.performed("workspace.search.matchCase", surfaceButton)
			v.matchCase = !v.matchCase
			f.Canvas().RequestFrame()
		}
		if f.Checkbox(searchOptionIDs.At(1), v.wholeWords).Label(i18n.Shared(a.language(), "native.wholeWords")).Clicked() {
			a.performed("workspace.search.wholeWords", surfaceButton)
			v.wholeWords = !v.wholeWords
			f.Canvas().RequestFrame()
		}
		if f.Checkbox(searchOptionIDs.At(2), v.regex).Label(i18n.Shared(a.language(), "native.regularExpression")).Clicked() {
			a.performed("workspace.search.regularExpression", surfaceButton)
			v.regex = !v.regex
			f.Canvas().RequestFrame()
		}
	})
	if dismiss {
		v.optionsOpen = false
	}
}

func (a *App) drawSearchResults(f *ui.Frame, p *project) {
	results := p.search.matches
	scroll := a.view.ScrollState(searchListID)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(scroll.Offset/searchResultHeight)-2)
	last := min(len(results), int((scroll.Offset+height)/searchResultHeight)+3)
	first = min(first, last)
	f.ScrollArea(searchListID).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		if first > 0 {
			f.Row().Height(float32(first) * searchResultHeight).Shrink(0)
		}
		for i := first; i < last; i++ {
			result := results[i]
			label := result.Path
			if result.Line != nil {
				label += ":" + strconv.Itoa(*result.Line)
			}
			row := f.Column().FillWidth().Height(searchResultHeight).Shrink(0).PadX(11).PadY(6).Gap(2).HitWith(searchRows.At(i), label, gfx.HitOptions{Role: gfx.RoleButton, Value: result.Preview, Cursor: gfx.PointerCursorHand}).Hover(ui.Look{}.Background(a.colors.Hover))
			row.Children(func() {
				f.Row().FillWidth().Items(ui.Center).Gap(6).Children(func() {
					name := filepath.Base(filepath.FromSlash(result.Path))
					f.Icon(fileicons.ForFile(name, a.colors.Dark)).Size(treeIcon, treeIcon).Shrink(0).Color(a.colors.Subtle)
					f.Text(name).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
					if result.Line != nil {
						f.Text(":" + strconv.Itoa(*result.Line)).FontSize(12).Color(a.colors.Subtle)
					}
				})
				f.Text(result.Preview).FontSize(11.5).Mono().Color(a.colors.Subtle).Ellipsis()
			})
			if row.Clicked() {
				a.performed("workspace.search.openResult", surfaceButton)
				a.openSearchResult(p, result)
			}
		}
		if rest := len(results) - last; rest > 0 {
			f.Row().Height(float32(rest) * searchResultHeight).Shrink(0)
		}
		if len(results) == searchMaxResults {
			f.Paragraph(i18n.Shared(a.language(), "desktop.search.first200"), 2).PadX(11).PadY(8).Color(a.colors.Subtle)
		}
	})
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

func (a *App) searchKey(event gfx.KeyEvent) gfx.EventResult {
	if !event.Release && event.Key == gfx.KeyEscape && a.searchView.optionsOpen {
		a.searchView.optionsOpen = false
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	index, ok := event.Target.In(searchRows)
	if !ok || event.Release || event.Modifiers != 0 || a.project == nil {
		return gfx.EventResult{}
	}
	results := a.project.search.matches
	if index < 0 || index >= len(results) {
		return gfx.EventResult{}
	}
	switch event.Key {
	case gfx.KeyUp:
		index = max(0, index-1)
	case gfx.KeyDown:
		index = min(len(results)-1, index+1)
	default:
		return gfx.EventResult{}
	}
	scroll := a.view.ScrollState(searchListID)
	top, bottom := float32(index)*searchResultHeight, float32(index+1)*searchResultHeight
	if top < scroll.Offset {
		scroll.ScrollTo(top)
	} else if bottom > scroll.Offset+scroll.Viewport {
		scroll.ScrollTo(bottom - scroll.Viewport)
	}
	a.searchView.rowFocus = searchRows.At(index)
	return gfx.EventResult{Handled: true, Repaint: true}
}
