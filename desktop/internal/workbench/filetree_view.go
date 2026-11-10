package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// treeFontSize is the size of the names in the tree.
const treeFontSize = 13

// treeScrollPad is the room after the end of the widest name when the tree is scrolled to its
// right end.
const treeScrollPad = 12

// treeOverscan is how many rows beyond the ones in view Viva's List and Tree declare each way,
// so the first row of the declared range is that many above the one at the top of the view.
const treeOverscan = 2

// treeChevron is the room Viva's Tree gives the chevron of a folder before its content.
const treeChevron = 24

// drawProjectTree puts the Project tool window's tree in the room under the panel header.
//
// Transitional adapter: the window still paints through a Frame, so the component is hosted
// by a Page registered with the page host. Delete this function and call projectTree directly
// once the workbench root window is a Page.
func (a *App) drawProjectTree(f *ui.Frame, p *project) {
	t := &p.tree
	if t.host.page == nil {
		t.host = a.newGitHost("project-tree", func(c ui.C) {
			if a.project == p {
				a.projectTree(c, p)
			}
		}, nil, panelPage{key: t.keyHook, wheel: t.wheelHook})
		t.wake = a.invalidator.Invalidate
		t.view.Node = t.describe
		t.view.Key = t.key
		t.view.Label = t.label
		t.view.RowHeight = treelist.RowHeight
		t.view.Indent = treelist.Indent
	}
	f.Slot().Fill().Draw(t.host.draw)
}

// keyHook notes an Enter pressed on a row, which the Tree reports as it does a click: Enter
// opens or closes a folder, and a click only selects it. The key is left to the page.
func (t *fileTree) keyHook(event gfx.KeyEvent) gfx.EventResult {
	if event.Key == gfx.KeyEnter && !event.Release && event.Modifiers == 0 && t.host.page != nil && t.host.page.Owns(event.Target) {
		t.enter = true
	}
	return gfx.EventResult{}
}

// wheelHook scrolls the rows sideways, by a sideways swipe or the wheel with Shift held, and
// leaves the page the rest. Viva's Tree lays its rows out RowWidth wide but, unlike its List,
// does not take the sideways wheel itself.
func (t *fileTree) wheelHook(event *gfx.ScrollEvent) {
	verticalWheel(event)
	dx := event.DeltaX
	if dx == 0 && event.Modifiers&gfx.ModifierShift != 0 {
		dx = event.DeltaY
		event.DeltaY = 0
	}
	if dx == 0 {
		return
	}
	event.DeltaX = 0
	if !event.Precise && dx > -treelist.RowHeight && dx < treelist.RowHeight {
		dx = treelist.RowHeight
		if event.DeltaX < 0 || event.DeltaX == 0 && event.DeltaY < 0 {
			dx = -dx
		}
	}
	t.view.ScrollToX(t.view.ScrollX() + dx)
	t.wake()
}

// key, label and describe the rows of the tree to its Tree.
func (t *fileTree) key(i int) int      { return t.rows[i].id }
func (t *fileTree) label(i int) string { return t.rows[i].name }

func (t *fileTree) describe(i int) ui.TreeNode {
	n := t.rows[i]
	return ui.TreeNode{Depth: n.depth, Branch: n.dir && !n.empty, Expanded: n.dir && n.expanded, Selected: n == t.selected}
}

// projectTree declares the body of the Project tool window: the rows of the project's
// folders and files, nested under the folders that are expanded. The root is listed the first
// time the tree is shown.
func (a *App) projectTree(c ui.C, p *project) {
	t := &p.tree
	if t.root == nil {
		t.root = &treeNode{name: p.name, dir: true, expanded: true}
		t.measureDirty = true
		a.listTree(p, "")
	}
	switch {
	case t.failed != "":
		ui.Column(c).Fill().Center().Gap(8).Children(func() {
			ui.Paragraph(c, a.text.Project.Failed(t.failed), 3).TextCenter().Color(a.colors.Subtle)
			if ui.Button(c, i18n.Shared(a.language(), "ui.retry")).Outline().Clicked() {
				c.After(func() { a.retryProjectTree(p) })
			}
		})
		return
	case !t.root.listed:
		a.panelMessage(c, a.text.Project.Loading, a.colors.Subtle)
		return
	}
	// Flatten the already loaded rows; the Tree declares only the viewport and a little
	// beyond it. Expanding a folder never enumerates its unexpanded descendants.
	t.rows = t.rows[:0]
	var collect func([]*treeNode)
	collect = func(nodes []*treeNode) {
		for _, n := range nodes {
			t.rows = append(t.rows, n)
			if n.dir && n.expanded {
				collect(n.children)
			}
		}
	}
	collect([]*treeNode{t.root})
	a.syncTreeSelection(c.Canvas(), t)
	t.view.RowWidth = a.measureTree(c.Canvas(), t)
	// Names are never cut short: the rows are as wide as the widest one, and the tree
	// scrolls sideways to show the rest of it.
	ui.Tree(c, &t.view, len(t.rows), t.label, func(i int) { a.drawTreeContent(c, p, t.rows[i]) }).Grow(1).FillWidth().PadY(treelist.PadY)
	if i, ok := t.view.Toggled(); ok && i < len(t.rows) {
		n := t.rows[i]
		c.After(func() {
			t.selected = n
			a.toggleFolder(p, n)
		})
	}
	// A click selects a folder and opens a file; a folder opens or closes on Enter and on a
	// double click, as the native tree does.
	enter := t.enter
	t.enter = false
	info, _ := c.Canvas().ClickInfo()
	doubled := info.Clicks >= 2
	if i, ok := t.view.Chosen(); ok && i < len(t.rows) {
		n := t.rows[i]
		c.After(func() {
			t.selected = n
			switch {
			case !n.dir:
				a.activateTreeNode(p, n)
			case enter || doubled:
				a.toggleFolder(p, n)
			}
		})
	}

}

// syncTreeSelection hands the model's selection to the Tree (it is the row Tab reaches) and
// scrolls a row to show to the middle of the view when it is out of view.
//
// Viva's Tree does not report the row the arrow keys moved to, so the selection follows a
// click, Enter or a chevron, and the arrows move the keyboard focus ring alone; this wants the
// row identities (TreeState.RowID) of a newer Viva to follow the focus.
func (a *App) syncTreeSelection(canvas *gfx.Canvas, t *fileTree) {
	selected := -1
	for i, n := range t.rows {
		if n == t.selected {
			selected = i
		}
		if n == t.show {
			first, last := t.view.Visible()
			if i < first || i > last {
				t.view.ScrollTo(i, ui.ListCenter)
				canvas.RequestFrame()
			}
			t.show = nil
		}
	}
	if t.view.Selected() != selected {
		t.view.Select(selected)
	}
}

// measureTree is how wide the widest row is: the width the rows are given so that every name
// shows whole. It is measured again only when rows came or went, or the font changed.
func (a *App) measureTree(canvas *gfx.Canvas, t *fileTree) float32 {
	font := float32(treeFontSize)
	if !t.measureDirty && t.measureFont == font {
		return t.view.RowWidth
	}
	width := float32(0)
	for _, n := range t.rows {
		weight := gfx.WeightRegular
		if n == t.root {
			weight = gfx.WeightSemibold
		}
		row := float32(n.depth*treelist.Indent) + treelist.Icon + treelist.Gap + canvas.TextWidthWeight(n.name, font, weight) + treelist.Trailing
		if n.dir && !n.empty {
			row += treeChevron
		}
		width = max(width, row)
	}
	t.measureDirty, t.measureFont = false, font
	return width + treeScrollPad
}

// drawTreeContent declares what a row of the tree shows after its chevron: the node's icon and
// its name, the root's in bold.
func (a *App) drawTreeContent(c ui.C, p *project, n *treeNode) {
	icon := fileicons.ForFile(n.name, a.colors.Dark)
	if n.dir {
		icon = fileicons.ForDirectory(n.name, a.colors.Dark)
	}
	ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
	name := ui.Text(c, n.name).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
	if n == p.tree.root {
		name.Bold()
	}
}
