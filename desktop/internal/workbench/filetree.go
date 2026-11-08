package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// Sizes of the project tree's rows.
const (
	// treeIndent is how far each level of the tree is moved in from its parent.
	treeIndent = 16
	// treeChevron is the size of the arrow before a folder, and of the room it takes before a
	// file, so the names of a folder's files line up with its subfolders' names.
	treeChevron = 12
	// treeIcon is the size of a row's file or folder icon.
	treeIcon = 14
	// treePad is the room before the first level of the tree.
	treePad = 8
	// treeEventSkipped is the log event of a folder the kernel could not list, so the tree
	// lacks its children, and treeSkippedLevel the level the kernel's event catalog declares
	// for it.
	treeEventSkipped = "app.workspace.directory_skipped"
	treeSkippedLevel = core.LevelWarn
)

// The identities of the project tree's controls: the list scrolls, and treeRows.At(n) is the
// row of the node with id n, which it keeps for as long as the project is open.
var (
	treeListID = tree.ID(shellPage, "project-tree")
	treeRows   = tree.Sub(shellPage, tree.Name("project-tree-rows"))
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
	// empty says the kernel knows the folder shows nothing, before or after it is listed.
	empty    bool
	children []*treeNode
	depth    int
}

// fileTree is the state of the Project tool window's tree of the project folder. The zero
// value is a tree that has not been asked for yet.
type fileTree struct {
	root *treeNode
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
	// area and content are the list and its column in the frame being drawn, and labels the
	// names on its rows; drawn says the frame declared them. areaRect is where the list was
	// painted, for the wheel, and empty when the tree is not shown.
	area, content flex.Box
	labels        []flex.Box
	drawn         bool
	areaRect      ui.Rect
}

// node makes a node of the tree from what the kernel listed.
func (t *fileTree) node(entry core.WorkspaceNode, depth int) *treeNode {
	t.next++
	return &treeNode{id: t.next, path: entry.Path, name: entry.Name, dir: entry.IsDirectory, empty: entry.Leaf, depth: depth}
}

// find is the node at path among the nodes that are listed, and nil when there is none.
func (t *fileTree) find(path string) *treeNode {
	var walk func(n *treeNode) *treeNode
	walk = func(n *treeNode) *treeNode {
		if n.path == path {
			return n
		}
		for _, child := range n.children {
			if found := walk(child); found != nil {
				return found
			}
		}
		return nil
	}
	if t.root == nil {
		return nil
	}
	return walk(t.root)
}

// listTree asks the kernel for the children of the folders at paths, away from the window
// thread, and puts them into the tree when they arrive. A folder that cannot be listed stays
// collapsed; the root that cannot be listed shows why.
func (a *App) listTree(p *project, paths ...string) {
	for _, path := range paths {
		if n := p.tree.find(path); n != nil {
			n.loading = true
		}
	}
	root := p.root
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		listings, err := a.kernel.ListDirectories(ctx, root, paths)
		return func(a *App) {
			t := &p.tree
			if err != nil {
				for _, path := range paths {
					a.emit(treeSkippedLevel, treeEventSkipped, treeSkippedFields(path, err))
					if n := t.find(path); n != nil {
						n.loading, n.expanded = false, false
						if n == t.root {
							t.failed = err.Error()
						}
					}
				}
				return
			}
			for _, listing := range listings {
				n := t.find(listing.Path)
				if n == nil {
					continue
				}
				n.children = n.children[:0]
				for _, child := range listing.Children {
					n.children = append(n.children, t.node(child, n.depth+1))
				}
				n.listed, n.loading, n.empty = true, false, len(n.children) == 0
			}
			for _, path := range paths {
				// A folder the kernel no longer lists is gone or hidden: it stops loading.
				if n := t.find(path); n != nil && n.loading {
					n.loading, n.expanded = false, false
				}
			}
		}
	})
}

// treeSkippedFields are the fields of app.workspace.directory_skipped for the folder at the
// workspace-relative path, where "" is the root, which the event names ".".
func treeSkippedFields(path string, err error) map[string]any {
	fields := logwindow.ErrorFields(err)
	if path == "" {
		path = "."
	}
	fields["path"] = path
	return fields
}

// toggleFolder expands a collapsed folder, listing it the first time, and collapses an
// expanded one.
func (a *App) toggleFolder(p *project, n *treeNode) {
	if n.expanded {
		n.expanded = false
		return
	}
	n.expanded = true
	if !n.listed && !n.loading && !n.empty {
		a.listTree(p, n.path)
	}
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
	if t.root == nil {
		t.root = &treeNode{name: p.name, dir: true, expanded: true}
		a.listTree(p, "")
	}
	t.rows = t.rows[:0]
	if t.byID == nil {
		t.byID = map[ui.ID]*treeNode{}
	}
	clear(t.byID)
	switch {
	case t.failed != "":
		a.drawTreeMessage(f, a.text.Project.Failed(t.failed))
		return
	case !t.root.listed:
		a.drawTreeMessage(f, a.text.Project.Loading)
		return
	case len(t.root.children) == 0:
		a.drawTreeMessage(f, a.text.Project.Empty)
		return
	}
	var clicked *treeNode
	t.labels = t.labels[:0]
	t.area = f.ScrollArea(treeListID).Fill().PadY(4)
	t.area.Children(func() {
		// Names are never cut short: the column is as wide as the widest row, and the list
		// scrolls sideways to show the rest of it.
		t.content = f.Column().Width(max(t.width, t.viewport)).Shrink(0).MarginSides(0, 0, 0, -t.scrollX)
		t.content.Children(func() {
			var rows func(nodes []*treeNode)
			rows = func(nodes []*treeNode) {
				for _, n := range nodes {
					if a.drawTreeRow(f, p, n) {
						clicked = n
					}
					if n.dir && n.expanded {
						rows(n.children)
					}
				}
			}
			rows(t.root.children)
		})
	})
	t.drawn = true
	if clicked != nil {
		a.activateTreeNode(p, clicked)
	}
}

// drawTreeMessage fills the tree's room with one line of words, for a tree that has no rows.
func (a *App) drawTreeMessage(f *flex.Frame, message string) {
	f.Row().Fill().Items(flex.Center).PadX(shellContentPad).Children(func() {
		f.Paragraph(message, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
	})
}

// drawTreeRow declares one row of the tree: the arrow of a folder, its icon and its name,
// moved in by its depth. It reports whether the row was clicked.
func (a *App) drawTreeRow(f *flex.Frame, p *project, n *treeNode) bool {
	t := &p.tree
	id := treeRows.At(n.id)
	t.rows = append(t.rows, n)
	t.byID[id] = n
	selected := t.selected == n
	row := f.Row().Height(rowHeight).FillWidth().Shrink(0).Items(flex.Center).Gap(4).
		PadSides(0, 8, 0, float32(treePad+n.depth*treeIndent)).
		HitWith(id, n.name, ui.HitOptions{Role: ui.RoleOption, Selected: selected, Expanded: n.dir && n.expanded}).
		Pressed(flex.Look{}.Background(a.colors.Active))
	if selected {
		row = row.Background(a.colors.Active)
	} else {
		row = row.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	row.Children(func() {
		switch {
		case !n.dir || n.empty:
			f.Row().Size(treeChevron, treeChevron).Shrink(0)
		case n.expanded:
			f.Icon(icons.ChevronDown).Size(treeChevron, treeChevron).Shrink(0).Color(a.colors.Subtle)
		default:
			f.Icon(icons.ChevronRight).Size(treeChevron, treeChevron).Shrink(0).Color(a.colors.Subtle)
		}
		icon := fileicons.ForFile(n.name, a.colors.Dark)
		if n.dir {
			icon = fileicons.ForDirectory(n.name, a.colors.Dark)
		}
		f.Icon(icon).Size(treeIcon, treeIcon).Shrink(0).Color(a.colors.Subtle)
		t.labels = append(t.labels, f.Text(n.name).Color(a.colors.Text).Shrink(0))
	})
	return row.Clicked()
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
			n.expanded = false
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
	left := t.content.Rect().X
	width := float32(0)
	for _, label := range t.labels {
		r := label.Rect()
		width = max(width, r.X+r.Width-left)
	}
	width += treeScrollPad
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
