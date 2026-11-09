package workbench

import (
	"context"
	"errors"
	"path"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// Sizes of the project tree's rows.
const (
	// treeIndent is how far each level of the tree is moved in from its parent.
	treeIndent = 19
	// treeChevron is the size of the arrow before a folder, and of the room it takes before a
	// file, so the names of a folder's files line up with its subfolders' names.
	treeChevron = 17
	// treeIcon is the size of a row's file or folder icon.
	treeIcon = 16
	// treeGutter is the shared horizontal inset of the native tree list.
	treeGutter = 12
)

// The identities of the project tree's controls: the list scrolls, and treeRows.At(n) is the
// row of the node with id n, which it keeps for as long as the project is open.
var (
	treeListID  = tree.ID(shellPage, "project-tree")
	treeRetryID = tree.ID(shellPage, "project-tree-retry")
	treeRows    = tree.Sub(shellPage, tree.Name("project-tree-rows"))
	treeArrows  = tree.Sub(shellPage, tree.Name("project-tree-arrows"))
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
	// rows are the rows the last frame declared, top to bottom, and byID finds the node of
	// a row's hit, for the keyboard.
	rows []*treeNode
	byID map[ui.ID]*treeNode
	// The tree scrolls sideways itself, as a flex scroll area scrolls only up and down: the
	// rows are laid out on a column as wide as the widest row, moved left by scrollX. width
	// is that widest row and viewport the width of the list, as the last frame measured them.
	scrollX, width, viewport float32
	// area and content are the list and its column in the frame being drawn; drawn says the
	// frame declared them. areaRect is where the list was
	// painted, for the wheel, and empty when the tree is not shown.
	area, content flex.Box
	focus         ui.ID
	measureDirty  bool
	measureFont   float32
	drawn         bool
	areaRect      ui.Rect
	// pending and reading coalesce native events into one bounded Core request.
	pending        map[string]*treeNode
	reading        bool
	watches        map[string]*documentWatch
	watchLimitHit  bool
	recursiveWatch bool
	resyncOnAttach bool
	eventPending   []string
	eventFiltering bool
	eventEpoch     uint64
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
		t.focus = ui.ID{}
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
			anchor, anchorOffset := a.treeViewportAnchor(t)
			loggedFailure := false
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
	offset := a.view.ScrollState(treeListID).Offset
	index := min(len(t.rows)-1, int(max(0, offset-4)/rowHeight))
	return t.rows[index], offset - (4 + float32(index)*rowHeight)
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
		a.view.ScrollState(treeListID).ScrollTo(4 + float32(index)*rowHeight + offset)
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
func (a *App) drawProjectTree(f *flex.Frame, p *project) {
	t := &p.tree
	if !t.focus.IsZero() {
		f.Canvas().RequestFocus(t.focus)
		t.focus = ui.ID{}
	}
	if t.root == nil {
		t.root = &treeNode{name: p.name, dir: true, expanded: true}
		t.measureDirty = true
		a.listTree(p, "")
	}
	t.rows = t.rows[:0]
	if t.byID == nil {
		t.byID = map[ui.ID]*treeNode{}
	}
	clear(t.byID)
	switch {
	case t.failed != "":
		f.Column().Fill().Center().Gap(8).Children(func() {
			f.Paragraph(a.text.Project.Failed(t.failed), 3).TextCenter().Color(a.colors.Subtle)
			if f.Button(treeRetryID, i18n.Shared(a.language(), "ui.retry")).Outline().Clicked() {
				if slot := t.watches[""]; slot != nil {
					slot.close()
					delete(t.watches, "")
				}
				t.failed, t.root.listed, t.root.expanded = "", false, true
				a.listTree(p, "")
			}
		})
		return
	case !t.root.listed:
		a.drawTreeMessage(f, a.text.Project.Loading)
		return
	}
	// Flatten the already loaded rows for keyboard navigation, but declare
	// controls only for the viewport and a small overscan. Expanding a folder
	// never enumerates its unexpanded descendants.
	var collect func([]*treeNode)
	collect = func(nodes []*treeNode) {
		for _, n := range nodes {
			t.rows = append(t.rows, n)
			t.byID[treeRows.At(n.id)] = n
			if n.dir && !n.empty {
				t.byID[treeArrows.At(n.id)] = n
			}
			if n.dir && n.expanded {
				collect(n.children)
			}
		}
	}
	collect([]*treeNode{t.root})
	scroll := a.view.ScrollState(treeListID)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(max(0, scroll.Offset-4)/rowHeight)-2)
	last := min(len(t.rows), int((scroll.Offset+height)/rowHeight)+3)
	first = min(first, last)
	var clicked, arrow *treeNode
	t.area = f.ScrollArea(treeListID).Fill().PadY(4)
	t.area.Children(func() {
		// Names are never cut short: the column is as wide as the widest row, and the list
		// scrolls sideways to show the rest of it.
		t.content = f.Column().Width(max(t.width, t.viewport)).Shrink(0).MarginSides(0, 0, 0, -t.scrollX)
		t.content.Children(func() {
			if first > 0 {
				f.Row().Height(float32(first) * rowHeight).Shrink(0)
			}
			for _, n := range t.rows[first:last] {
				rowClicked, arrowClicked := a.drawTreeRow(f, p, n)
				if rowClicked {
					clicked = n
				}
				if arrowClicked {
					arrow = n
				}
			}
			if rest := len(t.rows) - last; rest > 0 {
				f.Row().Height(float32(rest) * rowHeight).Shrink(0)
			}
		})
	})
	t.drawn = true
	if clicked != nil {
		if clicked.dir {
			t.selected = clicked
		} else {
			a.activateTreeNode(p, clicked)
		}
	}
	if arrow != nil {
		t.selected = arrow
		a.toggleFolder(p, arrow)
	}
}

// drawTreeMessage fills the tree's room with one line of words, for a tree that has no rows.
func (a *App) drawTreeMessage(f *flex.Frame, message string) {
	f.Row().Fill().Items(flex.Center).PadX(shellContentPad).Children(func() {
		f.Paragraph(message, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
	})
}

// drawTreeRow declares one row of the tree: the arrow of a folder, its icon and its name,
// moved in by its depth. The disclosure arrow is a separate hit target.
func (a *App) drawTreeRow(f *flex.Frame, p *project, n *treeNode) (bool, bool) {
	t := &p.tree
	id := treeRows.At(n.id)
	selected := t.selected == n
	_, rowFocused := f.Canvas().Focused().In(treeRows)
	_, arrowFocused := f.Canvas().Focused().In(treeArrows)
	focusedColor, inactiveColor := ui.RGB24(0xD0DFFE), ui.RGB24(0xE9EAEE)
	textColor := ui.RGB24(0x000000)
	hover := ui.RGB24(0x000000)
	hover.Alpha = 8.0 / 255
	if a.colors.Dark {
		focusedColor, inactiveColor = ui.RGB24(0x2A4371), ui.RGB24(0x33353B)
		textColor = ui.RGB24(0xD1D3D9)
		hover = ui.RGB24(0xFFFFFF)
		hover.Alpha = 16.0 / 255
	}
	row := f.Row().Height(rowHeight).FillWidth().Shrink(0).Items(flex.Center).Gap(2).
		MarginSides(0, treeGutter, 0, treeGutter).Radius(4).
		PadSides(0, 8, 0, float32(n.depth*treeIndent)).
		HitWith(id, n.name, ui.HitOptions{Role: ui.RoleOption, Selected: selected, Expandable: n.dir && !n.empty, Expanded: n.dir && n.expanded}).
		Pressed(flex.Look{}.Background(focusedColor))
	if selected {
		color := inactiveColor
		if rowFocused || arrowFocused {
			color = focusedColor
		}
		row = row.Background(color)
	} else {
		row = row.Hover(flex.Look{}.Background(hover))
	}
	arrowClicked := false
	row.Children(func() {
		switch {
		case !n.dir || n.empty:
			f.Row().Size(treeChevron, treeChevron).Shrink(0)
		default:
			label := i18n.Shared(a.language(), "native.expandDirectory")
			if n.expanded {
				label = i18n.Shared(a.language(), "native.collapseDirectory")
			}
			button := f.Row().Size(treeChevron, treeIcon).Shrink(0).Items(flex.Center).HitWith(treeArrows.At(n.id), label+" "+n.name, ui.HitOptions{Role: ui.RoleButton})
			button.Children(func() { f.Icon(fileicons.TreeChevron(n.expanded, a.colors.Dark)).Size(treeIcon, treeIcon) })
			arrowClicked = button.Clicked()
		}
		icon := fileicons.ForFile(n.name, a.colors.Dark)
		if n.dir {
			icon = fileicons.ForDirectory(n.name, a.colors.Dark)
		}
		f.Icon(icon).Size(treeIcon, treeIcon).Shrink(0).Color(a.colors.Subtle)
		name := f.Text(n.name).FontSize(13).Color(textColor).Shrink(0)
		if n == t.root {
			name.Bold()
		}
	})
	return row.Clicked(), arrowClicked
}

// A folder name selects on one click and toggles on the second press, matching
// the native tree. The ensuing release must not toggle it again.
func (a *App) treePointer(event ui.PointerEvent) (ui.EventResult, bool) {
	if a.project == nil || event.Kind != ui.PointerDown || event.Button != ui.PointerButtonPrimary || event.Modifiers != 0 || event.ClickCount != 2 {
		return ui.EventResult{}, false
	}
	if _, ok := event.Target.In(treeRows); !ok {
		return ui.EventResult{}, false
	}
	n := a.project.tree.byID[event.Target]
	if n == nil || !n.dir {
		return ui.EventResult{}, false
	}
	a.project.tree.selected = n
	if !n.empty {
		a.toggleFolder(a.project, n)
	}
	return ui.EventResult{Handled: true, Repaint: true}, true
}

// treeKey moves through the tree with the keyboard while one of its rows has the focus: the
// up and down arrows step between rows, right expands a folder or steps into it, left
// collapses it or steps out to its parent, and Enter opens the row.
func (a *App) treeKey(event ui.KeyEvent) ui.EventResult {
	p := a.project
	if p == nil || event.Release {
		return ui.EventResult{}
	}
	t := &p.tree
	n, ok := t.byID[event.Target]
	if !ok || event.Modifiers != 0 {
		return ui.EventResult{}
	}
	// The keyboard stays on the row that was clicked, and the arrows move the selection, so
	// the keys act on the selected row.
	if t.selected != nil {
		n = t.selected
	}
	at := -1
	for i, row := range t.rows {
		if row == n {
			at = i
			break
		}
	}
	move := func(i int) ui.EventResult {
		if i >= 0 && i < len(t.rows) {
			t.selected = t.rows[i]
			t.focus = treeRows.At(t.selected.id)
			scroll := a.view.ScrollState(treeListID)
			top := float32(4) + float32(i)*rowHeight
			bottom := top + rowHeight
			if top < scroll.Offset {
				scroll.ScrollTo(top)
			} else if bottom > scroll.Offset+scroll.Viewport {
				scroll.ScrollTo(bottom - scroll.Viewport)
			}
		}
		return ui.EventResult{Handled: true, Repaint: true}
	}
	switch event.Key {
	case ui.KeyUp:
		return move(at - 1)
	case ui.KeyDown:
		return move(at + 1)
	case ui.KeyRight:
		if n.dir && !n.expanded {
			t.selected = n
			a.toggleFolder(p, n)
			return ui.EventResult{Handled: true, Repaint: true}
		}
		if n.dir && len(n.children) > 0 {
			return move(at + 1)
		}
		return ui.EventResult{Handled: true}
	case ui.KeyLeft:
		if n.dir && n.expanded {
			t.selected = n
			a.toggleFolder(p, n)
			return ui.EventResult{Handled: true, Repaint: true}
		}
		for i := at - 1; i >= 0; i-- {
			if t.rows[i].depth < n.depth {
				return move(i)
			}
		}
		return ui.EventResult{Handled: true}
	case ui.KeyEnter:
		a.activateTreeNode(p, n)
		return ui.EventResult{Handled: true, Repaint: true}
	}
	return ui.EventResult{}
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
func (a *App) captureTree(canvas *ui.Canvas) {
	p := a.project
	if p == nil {
		return
	}
	t := &p.tree
	if !t.drawn {
		t.areaRect = ui.Rect{}
		return
	}
	t.drawn = false
	area := t.area.Rect()
	width := t.width
	fontSize := float32(13)
	if t.measureDirty || t.measureFont != fontSize {
		width = 0
		for _, n := range t.rows {
			prefix := float32(2*treeGutter + n.depth*treeIndent + treeChevron + treeIcon + 4 + 8)
			weight := ui.WeightRegular
			if n == t.root {
				weight = ui.WeightSemibold
			}
			width = max(width, prefix+canvas.TextWidthWeight(n.name, fontSize, weight))
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
	canvas.Rounded(ui.Rect{X: x, Y: area.Y + area.Height - treeBar - 2, Width: length, Height: treeBar}, treeBar/2, thumb)
}

// treeScroll scrolls the project tree sideways with a sideways swipe, or the wheel with Shift
// held, over the list. Up and down scrolling is the scroll area's own. The second result says
// whether the event was the tree's.
func (a *App) treeScroll(event ui.ScrollEvent) (ui.EventResult, bool) {
	p := a.project
	if p == nil {
		return ui.EventResult{}, false
	}
	t := &p.tree
	r := t.areaRect
	if r.Width <= 0 || event.X < r.X || event.X >= r.X+r.Width || event.Y < r.Y || event.Y >= r.Y+r.Height {
		return ui.EventResult{}, false
	}
	dx := event.DeltaX
	if dx == 0 && event.Modifiers&ui.ModifierShift != 0 {
		dx = event.DeltaY
	}
	if dx == 0 || absFloat32(dx) < absFloat32(event.DeltaY) && event.Modifiers&ui.ModifierShift == 0 {
		return ui.EventResult{}, false
	}
	if !event.Precise && absFloat32(dx) < rowHeight {
		dx = rowHeight * dx / absFloat32(dx)
	}
	before := t.scrollX
	t.scrollX = min(max(t.scrollX+dx, 0), max(t.width-t.viewport, 0))
	return ui.EventResult{Handled: true, Repaint: t.scrollX != before}, true
}
