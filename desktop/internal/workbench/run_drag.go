package workbench

import (
	"slices"

	"github.com/vivaui/viva/gfx"
)

// runDragSource identifies what a Run window drag started from: either a grouped session row
// in the left execution tree (dragged up to the tab bar to detach) or a tab in the Run header
// (dragged to reorder or merge back into its plugin group).
type runDragSource struct {
	isTreeRow bool
	sessionID string
	tabKey    string
	groupID   string
	detached  bool
	label     string
}

type runTabPlace struct {
	key            string
	groupID        string
	detached       bool
	firstSessionID string
	rect           gfx.Rect
}

// runDragPlaces holds the geometry and hit identities captured during the last paint of the
// Run tool window's tab bar and execution tree.
type runDragPlaces struct {
	sources  map[gfx.ID]runDragSource
	tabBar   gfx.Rect
	treePane gfx.Rect
	tabs     []runTabPlace
}

func (p *runDragPlaces) beginTabs() {
	if p.sources == nil {
		p.sources = map[gfx.ID]runDragSource{}
	}
	clear(p.sources)
	p.tabs = p.tabs[:0]
	p.tabBar = gfx.Rect{}
}

func (p *runDragPlaces) recordSource(id gfx.ID, src runDragSource) {
	if p.sources == nil {
		p.sources = map[gfx.ID]runDragSource{}
	}
	p.sources[id] = src
}

func (p *runDragPlaces) addTab(place runTabPlace) int {
	p.tabs = append(p.tabs, place)
	return len(p.tabs) - 1
}

type runDropKind uint8

const (
	runDropNone runDropKind = iota
	runDropDetach
	runDropReorder
	runDropMerge
)

type runDropTarget struct {
	kind        runDropKind
	beforeIndex int
	mergeIDs    []string
	preview     gfx.Rect
	line        gfx.Rect
	hasLine     bool
}

type runDragState struct {
	active   bool
	source   runDragSource
	x, y     float32
	viewport gfx.Size
	target   runDropTarget
}

func (a *App) runDragAccept(source, _ gfx.ID) bool {
	p := a.project
	if p == nil {
		return false
	}
	src, ok := a.dnd.runPlaces.sources[source]
	if !ok {
		return false
	}
	point := a.dnd.run.At()
	d := &a.dnd.runDrag
	d.active = true
	d.source = src
	d.x, d.y = point.X, point.Y
	d.viewport = a.viewport()
	d.target = a.runDragLocate(p, src, point)
	return d.target.kind != runDropNone
}

func (a *App) runDragDrop(_, _ gfx.ID) {
	d := a.dnd.runDrag
	a.dnd.runDrag = runDragState{}
	p := a.project
	if !d.active || p == nil {
		return
	}
	switch d.target.kind {
	case runDropDetach:
		a.performed("run.session.detach", surfaceDragDrop)
		p.detachRunSession(d.source.sessionID, d.target.beforeIndex)
	case runDropMerge:
		a.performed("run.session.merge", surfaceDragDrop)
		p.mergeRunSessions(d.target.mergeIDs...)
	case runDropReorder:
		a.performed("run.tab.reorder", surfaceDragDrop)
		p.reorderRunTab(d.source.tabKey, d.target.beforeIndex)
	}
}

func (a *App) runDragLocate(p *project, src runDragSource, point gfx.Point) runDropTarget {
	places := &a.dnd.runPlaces
	const barSlack = 8
	inTabBar := places.tabBar.Width > 0 && places.tabBar.Height > 0 &&
		point.X >= places.tabBar.X-barSlack && point.X <= places.tabBar.X+places.tabBar.Width+barSlack &&
		point.Y >= places.tabBar.Y-barSlack && point.Y <= places.tabBar.Y+places.tabBar.Height+barSlack

	if src.isTreeRow {
		if src.groupID == "" || src.detached || !inTabBar {
			return runDropTarget{}
		}
		before, line := runTabInsertion(places.tabBar, places.tabs, point.X)
		return runDropTarget{
			kind:        runDropDetach,
			beforeIndex: before,
			preview:     places.tabBar,
			line:        line,
			hasLine:     true,
		}
	}

	// Dragging a detached tab onto the active group's tree pane merges it back into the group.
	if src.detached && src.groupID != "" && places.treePane.Width > 0 && places.treePane.Height > 0 &&
		point.X >= places.treePane.X && point.X <= places.treePane.X+places.treePane.Width &&
		point.Y >= places.treePane.Y && point.Y <= places.treePane.Y+places.treePane.Height {
		if activeTab, _, ok := p.activeRunTab(); ok && activeTab.groupID == src.groupID && activeTab.key != src.tabKey {
			mergeIDs := []string{src.sessionID}
			if activeTab.detached && len(activeTab.entries) > 0 {
				mergeIDs = append(mergeIDs, activeTab.entries[0].id)
			}
			return runDropTarget{
				kind:     runDropMerge,
				mergeIDs: mergeIDs,
				preview:  places.treePane,
			}
		}
	}

	if !inTabBar {
		return runDropTarget{}
	}

	// Dragging a detached tab directly over another tab from the same plugin merges them.
	if src.detached && src.groupID != "" {
		for _, t := range places.tabs {
			if t.key == src.tabKey || t.groupID != src.groupID || t.rect.Width <= 0 {
				continue
			}
			inset := t.rect.Width * 0.15
			if point.X >= t.rect.X+inset && point.X <= t.rect.X+t.rect.Width-inset {
				mergeIDs := []string{src.sessionID}
				if t.detached && t.firstSessionID != "" {
					mergeIDs = append(mergeIDs, t.firstSessionID)
				}
				return runDropTarget{
					kind:     runDropMerge,
					mergeIDs: mergeIDs,
					preview:  t.rect,
				}
			}
		}
	}

	// Otherwise, reorder tabs within the Run header bar.
	srcIdx := slices.IndexFunc(places.tabs, func(t runTabPlace) bool { return t.key == src.tabKey })
	if srcIdx < 0 {
		return runDropTarget{}
	}
	before, line := runTabInsertion(places.tabBar, places.tabs, point.X)
	if before == srcIdx || before == srcIdx+1 {
		return runDropTarget{}
	}
	return runDropTarget{
		kind:        runDropReorder,
		beforeIndex: before,
		line:        line,
		hasLine:     true,
	}
}

func runTabInsertion(bar gfx.Rect, tabs []runTabPlace, x float32) (int, gfx.Rect) {
	before := len(tabs)
	for i, t := range tabs {
		if x < t.rect.X+t.rect.Width/2 {
			before = i
			break
		}
	}
	lineX := bar.X + 2
	switch {
	case len(tabs) == 0:
		lineX = bar.X + 2
	case before == 0:
		lineX = tabs[0].rect.X - 1
	case before >= len(tabs):
		last := tabs[len(tabs)-1].rect
		lineX = last.X + last.Width + 1
	default:
		prev := tabs[before-1].rect
		next := tabs[before].rect
		lineX = (prev.X + prev.Width + next.X) / 2
	}
	lineY := bar.Y + (bar.Height-rowHeight)/2
	return before, gfx.Rect{X: lineX - dragMark/2, Y: lineY, Width: dragMark, Height: rowHeight}
}

func (a *App) paintRunDrag(canvas *gfx.Canvas) {
	d := &a.dnd.runDrag
	if !d.active || a.project == nil {
		return
	}
	canvas.PushLayer(dragLayer)
	defer canvas.PopLayer()

	if target := d.target; target.kind != runDropNone {
		if target.preview.Width > 0 && target.preview.Height > 0 {
			canvas.Rounded(target.preview, dragZoneRadius, a.colors.Accent.WithAlpha(dragTargetTint))
		}
		if target.hasLine {
			canvas.Rounded(target.line, dragMark/2, a.colors.Accent)
		}
	}

	style := gfx.TextStyle{Size: a.theme.Metrics.FontSizeM, Weight: gfx.WeightRegular, Color: a.colors.Text}
	width := min(chromeEdge+canvas.TextWidthStyle(d.source.label, style)+chromeEdge, terminalChipMaxWidth)
	ghost := gfx.Rect{X: d.x + dragGhostOffset, Y: d.y + dragGhostOffset, Width: width, Height: rowHeight}
	if d.viewport.Width > 0 {
		ghost.X = max(min(ghost.X, d.viewport.Width-ghost.Width-dragGhostMargin), 0)
		ghost.Y = max(min(ghost.Y, d.viewport.Height-ghost.Height-dragGhostMargin), 0)
	}
	canvas.RoundedBorder(ghost, dragGhostRadius, 1, a.colors.Accent, a.colors.Ground)
	canvas.Label(d.source.label, gfx.Rect{
		X:      ghost.X + chromeEdge,
		Y:      ghost.Y,
		Width:  ghost.Width - 2*chromeEdge,
		Height: ghost.Height,
	}, style)
}
