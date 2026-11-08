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
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

var (
	everywhereQueryID   = tree.ID(shellPage, "everywhere-query")
	everywhereDismissID = tree.ID(shellPage, "everywhere-dismiss")
	everywhereCloseID   = tree.ID(shellPage, "everywhere-close")
	everywhereClearID   = tree.ID(shellPage, "everywhere-clear")
	everywhereMoreID    = tree.ID(shellPage, "everywhere-more")
	everywhereListID    = tree.ID(shellPage, "everywhere-list")
	everywhereTabs      = tree.Sub(shellPage, tree.Name("everywhere-tab"))
	everywhereRows      = tree.Sub(shellPage, tree.Name("everywhere-result"))
)

const (
	everywherePageSize   = 50
	everywhereMaxResults = 500
	everywhereDebounce   = 180 * time.Millisecond
	everywhereFileHeight = 24
	everywhereTextHeight = 40
)

type everywhereView struct {
	query       flex.Field
	open, focus bool
	scope       int
	// Tests can request zero delay without changing production timing.
	delay time.Duration
}

type everywhereSearch struct {
	query                    string
	scope                    int
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
	if !p.search.watchAttached && p.search.watch != nil {
		p.search.watch.close()
		p.search.watch = nil
		p.search.watchReady, p.search.watchAvailable = false, false
	}
	s.watchReady, s.watchAvailable, s.fullResync = false, false, true
	s.pending = nil
	a.everywhereView.open, a.everywhereView.focus = false, false
	a.everywhereView.query.SetText("")
}

func (a *App) updateEverywhere(p *project, query string, scope int) {
	s := &p.everywhere
	if s.query == query && s.scope == scope {
		return
	}
	s.query, s.scope = query, scope
	s.generation++
	s.matches, s.cursor, s.failed, s.selected = nil, nil, false, 0
	a.view.ScrollState(everywhereListID).ScrollTo(0)
	if s.cancel != nil {
		s.cancel()
	}
	if strings.TrimSpace(query) == "" {
		s.loading = false
		return
	}
	kinds := []string{"file", "type", "symbol"}
	if scope == 2 {
		kinds = []string{"file"}
	} else if scope == 5 {
		kinds = []string{"content"}
	}
	openPaths := make([]string, 0, len(p.docs.list))
	for _, doc := range p.docs.list {
		if relative, err := filepath.Rel(p.root, doc.path); err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			openPaths = append(openPaths, filepath.ToSlash(relative))
		}
	}
	s.request = core.EverywhereSearchRequest{Root: p.root, Query: query, PageSize: everywherePageSize, ResultKinds: kinds,
		IncludeGeneratedFileNames: scope != 5, Context: &core.EverywhereSearchContext{OpenPaths: openPaths}}
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
			a.notify(i18n.Shared(a.language(), "desktop.everywhere.watchUnavailable"))
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
			a.notify(i18n.Shared(a.language(), "desktop.everywhere.watchUnavailable"))
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
	s.loading = false
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			s.failed = true
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_search_everywhere", err))
		}
		return
	}
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

func (a *App) drawEverywhere(f *flex.Frame, p *project) {
	v, s := &a.everywhereView, &p.everywhere
	if !v.open {
		return
	}
	a.updateEverywhere(p, v.query.Text(), v.scope)
	if v.focus {
		f.Canvas().RequestFocus(everywhereQueryID)
		v.focus = false
	}
	if f.Popup().At(0, 0).Fill().HitWith(everywhereDismissID, a.text.Errors.Dismiss, ui.HitOptions{Role: ui.RoleButton, SkipFocus: true, Backdrop: true}).Clicked() {
		a.closeEverywhere(p)
		return
	}
	bounds := f.Bounds()
	width := min(float32(670), max(0, bounds.Width-32))
	height := float32(84)
	if strings.TrimSpace(v.query.Text()) != "" {
		height = min(684, max(84, bounds.Height-100))
	}
	background, border := ui.RGB24(0xF7F8F9), ui.RGB24(0xDDDFE4)
	if a.colors.Dark {
		background, border = ui.RGB24(0x26282C), ui.RGB24(0x33353B)
	}
	f.Popup().At((bounds.Width-width)/2, 84).Width(width).Height(height).
		Background(background).Border(1, border).Radius(a.theme.Metrics.RadiusPopup()).Shadow(ui.ShadowMD).Children(func() {
		f.Row().FillWidth().Height(40).Items(flex.Center).PadX(8).Gap(4).Children(func() {
			keys := []string{"desktop.everywhere.all", "desktop.everywhere.classes", "desktop.everywhere.files", "desktop.everywhere.symbols", "desktop.everywhere.actions", "desktop.everywhere.text"}
			for index, key := range keys {
				disabled := index == 1 || index == 3 || index == 4
				tab := f.Row().Height(30).PadX(8).Center().Radius(a.theme.Metrics.RadiusItem()).
					HitWith(everywhereTabs.At(index), i18n.Shared(a.language(), key), ui.HitOptions{Role: ui.RoleButton, Disabled: disabled, Cursor: ui.PointerCursorHand})
				if index == v.scope {
					tab = tab.Background(a.colors.Active)
				} else if !disabled {
					tab = tab.Hover(flex.Look{}.Background(a.colors.Hover))
				}
				color := a.colors.Text
				if disabled {
					color = a.colors.Subtle
				}
				tab.Children(func() { f.Text(i18n.Shared(a.language(), key)).FontSize(13).Color(color) })
				if !disabled && tab.Clicked() {
					a.performed("workspace.searchEverywhere.scope", surfaceButton)
					v.scope = index
					a.focusEverywhere(p)
					f.Canvas().RequestFrame()
				}
			}
			f.Row().Grow(1)
			closeButton := f.Row().Size(24, 24).Center().Radius(a.theme.Metrics.RadiusItem()).
				HitWith(everywhereCloseID, a.text.Errors.Dismiss, ui.HitOptions{Role: ui.RoleButton, Cursor: ui.PointerCursorHand}).Hover(flex.Look{}.Background(a.colors.Hover))
			closeButton.Children(func() { f.Icon(icons.X).Size(15, 15).Color(a.colors.Subtle) })
			if closeButton.Clicked() {
				a.closeEverywhere(p)
			}
		})
		f.Row().FillWidth().Height(1).Background(a.colors.Line)
		f.Row().FillWidth().PadSides(5, 8, 5, 8).Children(func() {
			var input flex.Box
			frame := f.Row().FillWidth().Height(30).Items(flex.Center).PadX(8).Gap(7).
				Border(1, a.theme.Input).Radius(a.theme.Metrics.RadiusControl).Focused(flex.Look{}.Border(a.theme.Primary).Ring(1, a.theme.Primary))
			frame.Children(func() {
				f.Icon(icons.Search).Size(15, 15).Color(a.colors.Subtle)
				input = f.FieldBase(&v.query, everywhereQueryID, i18n.Shared(a.language(), "desktop.everywhere.title"), "").Grow(1).MinWidth(0).Height(28).FontSize(13).Color(a.colors.Text)
				if v.query.Text() != "" && a.drawSearchClear(f, everywhereClearID) {
					v.query.SetText("")
					a.focusEverywhere(p)
					f.Canvas().RequestFrame()
				}
			})
			frame.StateFrom(input)
		})
		if strings.TrimSpace(v.query.Text()) == "" {
			return
		}
		switch {
		case s.loading && len(s.matches) == 0:
			f.Text(i18n.Shared(a.language(), "quickOpen.searching")).Pad(12).Color(a.colors.Subtle)
		case s.failed && len(s.matches) == 0:
			f.Text(i18n.Shared(a.language(), "search.failed")).Pad(12).Color(a.theme.Danger)
		case len(s.matches) == 0:
			f.Text(i18n.Shared(a.language(), "native.noMatches")).Pad(12).Color(a.colors.Subtle)
		default:
			a.drawEverywhereResults(f, p)
		}
	})
}

func (a *App) drawEverywhereResults(f *flex.Frame, p *project) {
	s := &p.everywhere
	rowHeight := everywhereFileHeight
	if s.scope == 5 {
		rowHeight = everywhereTextHeight
	}
	scroll := a.view.ScrollState(everywhereListID)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(scroll.Offset/float32(rowHeight))-2)
	last := min(len(s.matches), int((scroll.Offset+height)/float32(rowHeight))+3)
	first = min(first, last)
	f.ScrollArea(everywhereListID).FillWidth().Grow(1).Shrink(1).MinHeight(0).PadX(8).Children(func() {
		if first > 0 {
			f.Row().Height(float32(first * rowHeight)).Shrink(0)
		}
		for i := first; i < last; i++ {
			result := s.matches[i]
			label := result.Path
			if result.Line != nil {
				label += ":" + strconv.Itoa(*result.Line)
			}
			row := f.Row().FillWidth().Height(float32(rowHeight)).Items(flex.Center).PadX(10).Gap(8).Radius(a.theme.Metrics.RadiusItem()).
				HitWith(everywhereRows.At(i), label, ui.HitOptions{Role: ui.RoleButton, Value: result.Preview, Cursor: ui.PointerCursorHand})
			if i == s.selected {
				row = row.Background(a.colors.Selection)
			} else {
				row = row.Hover(flex.Look{}.Background(a.colors.Hover))
			}
			row.Children(func() {
				name := filepath.Base(filepath.FromSlash(result.Path))
				f.Icon(fileicons.ForFile(name, a.colors.Dark)).Size(16, 16).Color(a.colors.Subtle)
				if result.Kind == "content" {
					f.Column().Grow(1).Shrink(1).MinWidth(0).Children(func() {
						f.Text(result.Preview).Mono().FontSize(12).Color(a.colors.Text).Ellipsis()
						f.Text(label).FontSize(11).Color(a.colors.Subtle).Ellipsis()
					})
				} else {
					f.Text(name).Grow(1).Shrink(1).MinWidth(0).FontSize(13).Color(a.colors.Text).Ellipsis()
					f.Text(result.Path).FontSize(12).Color(a.colors.Subtle).Ellipsis()
				}
			})
			if row.Clicked() {
				a.performed("workspace.searchEverywhere.openResult", surfaceButton)
				a.closeEverywhere(p)
				a.openSearchResult(p, result)
			}
		}
		if rest := len(s.matches) - last; rest > 0 {
			f.Row().Height(float32(rest * rowHeight)).Shrink(0)
		}
		if s.failed {
			f.Text(i18n.Shared(a.language(), "search.failed")).Pad(8).Color(a.theme.Danger)
		}
		if s.cursor != nil && len(s.matches) >= everywhereMaxResults {
			f.Paragraph(i18n.Shared(a.language(), "desktop.everywhere.limit"), 2).Pad(8).Color(a.colors.Subtle)
		} else if s.cursor != nil {
			if f.Button(everywhereMoreID, i18n.Shared(a.language(), "desktop.everywhere.more")).Outline().Disabled(s.loading).Clicked() {
				a.performed("workspace.searchEverywhere.more", surfaceButton)
				a.runEverywhere(p, true)
			}
		}
	})
}

func (a *App) everywhereKey(p *project, event ui.KeyEvent) ui.EventResult {
	if event.Release || event.Modifiers != 0 {
		return ui.EventResult{}
	}
	if event.Target == everywhereQueryID {
		input := a.fields(app.TextInputContext{ID: everywhereQueryID})
		if input != nil && input.Editor != nil {
			if _, composing := input.Editor.Composition(); composing {
				return ui.EventResult{}
			}
		}
	}
	s := &p.everywhere
	switch event.Key {
	case ui.KeyEscape:
		a.closeEverywhere(p)
		return ui.EventResult{Handled: true, Repaint: true}
	case ui.KeyUp:
		s.selected = max(0, s.selected-1)
	case ui.KeyDown:
		s.selected = min(max(0, len(s.matches)-1), s.selected+1)
	case ui.KeyEnter:
		if s.selected >= 0 && s.selected < len(s.matches) {
			result := s.matches[s.selected]
			a.performed("workspace.searchEverywhere.openResult", surfaceShortcut)
			a.closeEverywhere(p)
			a.openSearchResult(p, result)
		}
		return ui.EventResult{Handled: true, Repaint: true}
	default:
		return ui.EventResult{}
	}
	scroll := a.view.ScrollState(everywhereListID)
	rowHeight := everywhereFileHeight
	if s.scope == 5 {
		rowHeight = everywhereTextHeight
	}
	top, bottom := float32(s.selected*rowHeight), float32((s.selected+1)*rowHeight)
	if top < scroll.Offset {
		scroll.ScrollTo(top)
	} else if bottom > scroll.Offset+scroll.Viewport {
		scroll.ScrollTo(bottom - scroll.Viewport)
	}
	return ui.EventResult{Handled: true, Repaint: true}
}
