package workbench

import (
	"context"
	"errors"
	"path"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The identities of the project tree's controls: the list scrolls, and treeRows.At(n) is the
// row of the node with id n, which it keeps for as long as the project is open.
var (
	treeListID  = tree.ID(shellPage, "project-tree")
	treeRetryID = tree.ID(shellPage, "project-tree-retry")
	treeRows    = tree.Sub(shellPage, tree.Name("project-tree-rows"))
	treeArrows  = tree.Sub(shellPage, tree.Name("project-tree-arrows"))
	treeList    = treelist.List{Scroll: treeListID, Rows: treeRows, Arrows: treeArrows}
	// treeActions.At(n) is the header button treeAction n.
	treeActions = tree.Sub(shellPage, tree.Name("project-tree-actions"))
)

// treeNode is a file or a folder of the project tree. A folder's children are listed by the
// kernel the first time it is expanded.
type treeNode struct {
	// id identifies the node's row; it is never reused.
	id int
	// path is relative to the project root with "/" separators; empty for the root.
	path     string
	name     string
	dir      bool
	expanded bool
	// listed says children is the kernel's listing; loading says the listing was asked for.
	listed, loading bool
	// revision advances as native notifications arrive, invalidating older reads.
	revision uint64
	// empty says the kernel knows the folder shows nothing, before or after it is listed.
	empty    bool
	children []*treeNode
	depth    int
}

// fileTree is the state of the Project tool window's tree of the project folder. The zero
// value is a tree that has not been asked for yet.
type fileTree struct {
	root *treeNode
	// byPath indexes only already loaded nodes; it never enumerates disk.
	byPath map[string]*treeNode
	// selected is the node whose row is highlighted, which the arrow keys move.
	selected *treeNode
	// failed is why the root could not be listed; empty otherwise.
	failed string
	next   int
	// rows are the nodes the last frame showed, top to bottom, and list the same rows as the
	// tree list draws them; the list declares only the ones in view.
	rows []*treeNode
	list []treelist.Row
	// The tree scrolls sideways itself, as a ui scroll area scrolls only up and down: the
	// rows are laid out on a column as wide as the widest row, moved left by scrollX. width
	// is that widest row and viewport the width of the list, as the last frame measured them.
	scrollX, width, viewport float32
	// area and content are the list and its column in the frame being drawn; drawn says the
	// frame declared them. areaRect is where the list was
	// painted, for the wheel, and empty when the tree is not shown.
	area, content ui.Box
	focus         gfx.ID
	measureDirty  bool
	measureFont   float32
	drawn         bool
	areaRect      gfx.Rect
	// pending and reading coalesce native events into one bounded Core request.
	pending map[string]*treeNode
	reading bool
	// failureReported says the current run of listing failures was already logged. A
	// user action can need several requests — a frame that paints while the first one
	// is in flight adds more paths — and each of them failing is one error to the user,
	// not one per request.
	failureReported bool
	watches         map[string]*documentWatch
	watchLimitHit   bool
	recursiveWatch  bool
	resyncOnAttach  bool
	eventPending    []string
	eventFiltering  bool
	eventEpoch      uint64
	// reveal is the path of the file the locate button is bringing into view while the
	// folders above it are still being listed, and empty otherwise; revealAsked is the
	// folder whose listing it waits for. show is a row the next frame scrolls to the middle
	// of the list, unless it is in view already.
	reveal      string
	revealAsked *treeNode
	show        *treeNode
	// expandingAll says Expand All is still opening folders as their listings arrive.
	// expandSeen is the ids of the folders it opened, each of them once and no more than
	// treeExpandAllLimit of them. refreshing says the refresh button is reading the
	// listings again.
	expandingAll bool
	expandSeen   map[int]bool
	refreshing   bool
}

// node makes a node of the tree from what the kernel listed.
func (t *fileTree) node(entry core.WorkspaceNode, depth int) *treeNode {
	t.next++
	return &treeNode{id: t.next, path: entry.Path, name: entry.Name, dir: entry.IsDirectory, empty: entry.Leaf, depth: depth}
}

// find is the node at path among the nodes that are listed, and nil when there is none.
func (t *fileTree) find(path string) *treeNode {
	if t.root == nil {
		return nil
	}
	if t.byPath == nil {
		t.byPath = make(map[string]*treeNode)
		var walk func(*treeNode)
		walk = func(n *treeNode) {
			t.byPath[n.path] = n
			for _, child := range n.children {
				walk(child)
			}
		}
		walk(t.root)
	}
	return t.byPath[path]
}

func (t *fileTree) forgetNode(n *treeNode) {
	if t.byPath == nil {
		return
	}
	delete(t.byPath, n.path)
	for _, child := range n.children {
		t.forgetNode(child)
	}
}

// replaceChildren keeps the identities and loaded descendants of entries that
// still exist. Selection must never point into a subtree that has disappeared.
func (t *fileTree) replaceChildren(parent *treeNode, entries []core.WorkspaceNode) {
	old := make(map[string]*treeNode, len(parent.children))
	for _, child := range parent.children {
		old[child.path] = child
	}
	children := make([]*treeNode, 0, len(entries))
	for _, entry := range entries {
		child := old[entry.Path]
		delete(old, entry.Path)
		if child == nil || child.dir != entry.IsDirectory {
			if child != nil {
				t.forgetNode(child)
			}
			child = t.node(entry, parent.depth+1)
		} else {
			child.name, child.empty = entry.Name, entry.Leaf
			if child.empty {
				child.listed = true
				for _, descendant := range child.children {
					t.forgetNode(descendant)
				}
				child.children = nil
			}
		}
		if t.byPath != nil {
			t.byPath[child.path] = child
		}
		children = append(children, child)
	}
	for _, removed := range old {
		t.forgetNode(removed)
	}
	parent.children = children
	if t.selected != nil && t.find(t.selected.path) != t.selected {
		selectedPath := t.selected.path
		t.selected = nil
		t.focus = gfx.ID{}
		for ancestor := path.Dir(selectedPath); ancestor != "." && ancestor != "/"; ancestor = path.Dir(ancestor) {
			if n := t.find(ancestor); n != nil && n.dir {
				t.selected = n
				t.focus = treeRows.At(n.id)
				break
			}
		}
	}
	t.measureDirty = true
}

// listTree asks the kernel for the children of the folders at paths, away from the window
// thread, and puts them into the tree when they arrive. A folder that cannot be listed stays
// collapsed; the root that cannot be listed shows why.
func (a *App) listTree(p *project, paths ...string) {
	t := &p.tree
	if t.pending == nil {
		t.pending = make(map[string]*treeNode)
	}
	for _, path := range paths {
		n := t.find(path)
		if n == nil || !n.dir {
			continue
		}
		a.watchTreeNode(p, n)
		n.revision++
		n.loading = true
		t.pending[path] = n
	}
	if t.resyncOnAttach {
		t.resyncOnAttach = false
		a.resyncTreeListings(p)
	}
	a.pumpTreeListings(p)
}

const treeListingBatch = 64

// pumpTreeListings keeps only one bounded request in flight. A notification
// during a read advances its node's revision, so that read cannot publish stale
// children; the queued replacement will use the latest disk state.
func (a *App) pumpTreeListings(p *project) {
	t := &p.tree
	if t.reading || len(t.pending) == 0 {
		return
	}
	type requested struct {
		node     *treeNode
		revision uint64
	}
	batch := make(map[string]requested, treeListingBatch)
	paths := make([]string, 0, treeListingBatch)
	for path, node := range t.pending {
		delete(t.pending, path)
		if t.find(path) != node {
			continue
		}
		batch[path] = requested{node, node.revision}
		paths = append(paths, path)
		if len(paths) == treeListingBatch {
			break
		}
	}
	if len(paths) == 0 {
		return
	}
	t.reading = true
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		listings, err := a.kernel.ListDirectories(ctx, p.root, paths)
		return func(a *App) {
			t.reading = false
			if err == nil {
				// The tree listed again, so a later failure is a new one to report.
				t.failureReported = false
			}
			anchor, anchorOffset := a.treeViewportAnchor(t)
			loggedFailure := t.failureReported
			byPath := make(map[string]core.DirectoryListing, len(listings))
			for _, listing := range listings {
				byPath[listing.Path] = listing
			}
			for _, path := range paths {
				req := batch[path]
				n := req.node
				if t.find(path) != n || n.revision != req.revision {
					continue
				}
				n.loading = false
				if err != nil {
					if !loggedFailure {
						a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_list", err))
						loggedFailure = true
						t.failureReported = true
					}
					if n == t.root {
						t.failed = i18n.Shared(a.language(), "desktop.project.rootUnavailable")
					} else if !n.listed {
						n.expanded = false
					}
					continue
				}
				if listing, ok := byPath[path]; ok {
					t.replaceChildren(n, listing.Children)
					n.listed, n.empty = true, len(n.children) == 0
					if n == t.root {
						t.failed = ""
					}
				} else {
					if n == t.root {
						a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("project_tree_list", errors.New("workspace root unavailable")))
						t.failed = i18n.Shared(a.language(), "desktop.project.rootUnavailable")
					} else {
						// log-exempt: 目标已消失：目录可能已被外部删除或隐藏。
						n.expanded = false
					}
				}
			}
			a.restoreTreeViewportAnchor(t, anchor, anchorOffset)
			a.pruneTreeWatches(p)
			if t.failed == "" {
				for _, path := range paths {
					if parent := t.find(path); parent != nil && parent.expanded {
						for _, child := range parent.children {
							if child.dir && child.empty {
								a.watchTreeNode(p, child)
							}
						}
					}
				}
			}
			a.pumpTreeListings(p)
			a.continueTreeActions(p)
		}
	})
}

// Keep the first visible row and its pixel offset stable when an asynchronous
// listing inserts or removes rows above it. Selection is independent of this
// anchor: the selected row may be outside the viewport.
func (a *App) treeViewportAnchor(t *fileTree) (*treeNode, float32) {
	if t.areaRect.Width <= 0 || len(t.rows) == 0 {
		return nil, 0
	}
	index, offset := treeList.TopRow(&a.view, len(t.rows))
	return t.rows[index], offset
}

func (a *App) restoreTreeViewportAnchor(t *fileTree, anchor *treeNode, offset float32) {
	if anchor == nil || t.root == nil {
		return
	}
	index, found := 0, false
	var visit func([]*treeNode)
	visit = func(nodes []*treeNode) {
		for _, n := range nodes {
			if found {
				return
			}
			if n == anchor {
				found = true
				return
			}
			index++
			if n.dir && n.expanded {
				visit(n.children)
			}
		}
	}
	visit([]*treeNode{t.root})
	if found {
		treeList.ScrollToRow(&a.view, index, offset)
	}
}

// toggleFolder expands a collapsed folder, listing it the first time, and collapses an
// expanded one.
func (a *App) toggleFolder(p *project, n *treeNode) {
	if n.empty {
		return
	}
	if n.expanded {
		n.expanded = false
		p.tree.measureDirty = true
		a.pruneTreeWatches(p)
		return
	}
	n.expanded = true
	p.tree.measureDirty = true
	// The directory may have changed while collapsed and unobserved.
	a.listTree(p, n.path)
}

// activateTreeNode does what a click or Enter on a row asks for: a folder opens or closes,
// and a file opens in the editor.
func (a *App) activateTreeNode(p *project, n *treeNode) {
	p.tree.selected = n
	if n.dir {
		a.toggleFolder(p, n)
		return
	}
	a.openFile(p, filepath.Join(p.root, filepath.FromSlash(n.path)))
}

// drawProjectTree declares the body of the Project tool window: the rows of the project's
// folders and files, nested under the folders that are expanded. The root is listed the first
// time the tree is shown.
func (a *App) drawProjectTree(f *ui.Frame, p *project) {
	t := &p.tree
	if !t.focus.IsZero() {
		f.Canvas().RequestFocus(t.focus)
		t.focus = gfx.ID{}
	}
	if t.root == nil {
		t.root = &treeNode{name: p.name, dir: true, expanded: true}
		t.measureDirty = true
		a.listTree(p, "")
	}
	t.rows, t.list = t.rows[:0], t.list[:0]
	switch {
	case t.failed != "":
		f.Column().Fill().Center().Gap(8).Children(func() {
			f.Paragraph(a.text.Project.Failed(t.failed), 3).TextCenter().Color(a.colors.Subtle)
			if f.Button(treeRetryID, i18n.Shared(a.language(), "ui.retry")).Outline().Clicked() {
				a.retryProjectTree(p)
			}
		})
		return
	case !t.root.listed:
		a.drawTreeMessage(f, a.text.Project.Loading)
		return
	}
	// Flatten the already loaded rows for keyboard navigation; the list declares controls
	// only for the viewport and a small overscan. Expanding a folder never enumerates its
	// unexpanded descendants.
	selected := -1
	var collect func([]*treeNode)
	collect = func(nodes []*treeNode) {
		for _, n := range nodes {
			if n == t.selected {
				selected = len(t.rows)
			}
			t.rows = append(t.rows, n)
			t.list = append(t.list, treelist.Row{Key: n.id, Label: n.name, Depth: n.depth, Branch: n.dir && !n.empty, Expanded: n.dir && n.expanded})
			if n.dir && n.expanded {
				collect(n.children)
			}
		}
	}
	collect([]*treeNode{t.root})
	if t.show != nil {
		if i := treelist.Index(t.list, t.show.id); i >= 0 {
			treeList.Center(&a.view, i)
		}
		t.show = nil
	}
	// Names are never cut short: the column is as wide as the widest row, and the list
	// scrolls sideways to show the rest of it.
	result := treeList.Draw(f, &a.view, t.list, selected, treelist.Options{
		Dark:     a.colors.Dark,
		Expand:   i18n.Shared(a.language(), "native.expandDirectory"),
		Collapse: i18n.Shared(a.language(), "native.collapseDirectory"),
		Width:    max(t.width, t.viewport),
		OffsetX:  t.scrollX,
	}, func(i int) { a.drawTreeContent(f, p, t.rows[i]) })
	t.area, t.content, t.drawn = result.Area, result.Content, true
	if result.Clicked >= 0 {
		if n := t.rows[result.Clicked]; n.dir {
			t.selected = n
		} else {
			a.activateTreeNode(p, n)
		}
	}
	if result.Toggled >= 0 {
		n := t.rows[result.Toggled]
		t.selected = n
		a.toggleFolder(p, n)
	}
}

// drawTreeMessage fills the tree's room with one line of words, for a tree that has no rows.
func (a *App) drawTreeMessage(f *ui.Frame, message string) {
	f.Row().Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
		f.Paragraph(message, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
	})
}

// drawTreeContent declares what a row of the tree shows after its arrow: the node's icon and
// its name, the root's in bold.
func (a *App) drawTreeContent(f *ui.Frame, p *project, n *treeNode) {
	icon := fileicons.ForFile(n.name, a.colors.Dark)
	if n.dir {
		icon = fileicons.ForDirectory(n.name, a.colors.Dark)
	}
	f.Icon(icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
	name := f.Text(n.name).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
	if n == p.tree.root {
		name.Bold()
	}
}

// treeFontSize is the size of the names in the tree.
const treeFontSize = 13

// treeNodeAt is the node of the row with key, the id of its node, among the rows the last
// frame showed; nil when it is not one of them.
func (t *fileTree) treeNodeAt(key int) *treeNode {
	if i := treelist.Index(t.list, key); i >= 0 {
		return t.rows[i]
	}
	return nil
}

// A folder name selects on one click and toggles on the second press, matching
// the native tree. The ensuing release must not toggle it again.
func (a *App) treePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if a.project == nil {
		return gfx.EventResult{}, false
	}
	key, ok := treeList.DoubleClicked(event)
	if !ok {
		return gfx.EventResult{}, false
	}
	n := a.project.tree.treeNodeAt(key)
	if n == nil || !n.dir {
		return gfx.EventResult{}, false
	}
	a.project.tree.selected = n
	if !n.empty {
		a.toggleFolder(a.project, n)
	}
	return gfx.EventResult{Handled: true, Repaint: true}, true
}

// treeKey moves through the tree with the keyboard while one of its rows has the focus: the
// up and down arrows step between rows, right expands a folder or steps into it, left
// collapses it or steps out to its parent, Home, End and the page keys jump, and Enter opens
// the row. The keyboard stays on the row that was clicked while the arrows move the
// selection, so the keys act on the selected row.
func (a *App) treeKey(event gfx.KeyEvent) gfx.EventResult {
	p := a.project
	if p == nil {
		return gfx.EventResult{}
	}
	t := &p.tree
	current := -1
	if t.selected != nil {
		current = treelist.Index(t.list, t.selected.id)
	}
	action, i, ok := treeList.Key(event, &a.view, t.list, current)
	if !ok {
		return gfx.EventResult{}
	}
	switch action {
	case treelist.Select:
		t.selected = t.rows[i]
		t.focus = treeRows.At(t.selected.id)
	case treelist.Expand, treelist.Collapse:
		t.selected = t.rows[i]
		a.toggleFolder(p, t.rows[i])
	case treelist.Activate:
		a.activateTreeNode(p, t.rows[i])
	default:
		return gfx.EventResult{Handled: true}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}

// treeScrollPad is the room after the end of the widest name when the tree is scrolled to its
// right end, and treeBar the thickness of the sideways scrollbar's thumb.
const (
	treeScrollPad = 12
	treeBar       = 6
)

// captureTree reads what the frame just laid out for the project tree: how wide its widest
// row is and how wide its list, keeping the sideways scroll in range. It paints the thumb of
// the sideways scrollbar along the bottom of the list while there is more to scroll to.
func (a *App) captureTree(canvas *gfx.Canvas) {
	p := a.project
	if p == nil {
		return
	}
	t := &p.tree
	if !t.drawn {
		t.areaRect = gfx.Rect{}
		return
	}
	t.drawn = false
	area := t.area.Rect()
	width := t.width
	fontSize := float32(treeFontSize)
	if t.measureDirty || t.measureFont != fontSize {
		width = 0
		for _, n := range t.rows {
			weight := gfx.WeightRegular
			if n == t.root {
				weight = gfx.WeightSemibold
			}
			width = max(width, treelist.Width(n.depth, treelist.Icon+treelist.Gap+canvas.TextWidthWeight(n.name, fontSize, weight)))
		}
		width += treeScrollPad
		t.measureDirty, t.measureFont = false, fontSize
	}
	viewport := area.Width
	scrollX := min(max(t.scrollX, 0), max(width-viewport, 0))
	if width != t.width || viewport != t.viewport || scrollX != t.scrollX {
		t.width, t.viewport, t.scrollX = width, viewport, scrollX
		canvas.RequestFrame()
	}
	t.areaRect = area
	if width <= viewport+0.5 || viewport <= 0 {
		return
	}
	length := max(viewport*viewport/width, 24)
	x := area.X + (viewport-length)*(t.scrollX/(width-viewport))
	thumb := a.colors.Subtle
	thumb.Alpha *= 0.45
	canvas.Rounded(gfx.Rect{X: x, Y: area.Y + area.Height - treeBar - 2, Width: length, Height: treeBar}, treeBar/2, thumb)
}

// treeScroll scrolls the project tree sideways with a sideways swipe, or the wheel with Shift
// held, over the list. Up and down scrolling is the scroll area's own. The second result says
// whether the event was the tree's.
func (a *App) treeScroll(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	p := a.project
	if p == nil {
		return gfx.EventResult{}, false
	}
	t := &p.tree
	r := t.areaRect
	if r.Width <= 0 || event.X < r.X || event.X >= r.X+r.Width || event.Y < r.Y || event.Y >= r.Y+r.Height {
		return gfx.EventResult{}, false
	}
	dx := event.DeltaX
	if dx == 0 && event.Modifiers&gfx.ModifierShift != 0 {
		dx = event.DeltaY
	}
	if dx == 0 || absFloat32(dx) < absFloat32(event.DeltaY) && event.Modifiers&gfx.ModifierShift == 0 {
		return gfx.EventResult{}, false
	}
	if !event.Precise && absFloat32(dx) < rowHeight {
		dx = rowHeight * dx / absFloat32(dx)
	}
	before := t.scrollX
	t.scrollX = min(max(t.scrollX+dx, 0), max(t.width-t.viewport, 0))
	return gfx.EventResult{Handled: true, Repaint: t.scrollX != before}, true
}
