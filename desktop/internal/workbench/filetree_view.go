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
	a.treePromptDialog(c, p)
	if t.wake == nil {
		t.wake = a.invalidator.Invalidate
		t.view.Node = t.describe
		t.view.Key = t.key
		t.view.Label = t.label
		t.view.RowHeight = treelist.RowHeight
		t.view.Indent = treelist.Indent
	}
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
	tree := ui.Tree(c, &t.view, len(t.rows), t.label, func(i int) { a.drawTreeContent(c, p, t.rows[i]) }).Grow(1).FillWidth().PadY(treelist.PadY)
	if tree.Shortcut(0, "f4") {
		c.After(func() { a.openSelectedTreeFile(p) })
	}
	tree.Draw(t.areaHook())
	a.focusTreeRow(c.Canvas(), t)
	if i, ok := t.view.Toggled(); ok && i < len(t.rows) {
		n := t.rows[i]
		c.After(func() {
			t.selected = n
			a.toggleFolder(p, n)
		})
	}
	// A click opens a file, and opens or closes a folder anywhere on its row, not only on its
	// arrow; Enter does the same. The second click of a double click leaves the folder as the
	// first one left it. Enter is a choice with no click behind it.
	info, clicked := c.Canvas().ClickInfo()
	repeated := clicked && info.Clicks >= 2
	if i, ok := t.view.Chosen(); ok && i < len(t.rows) {
		n := t.rows[i]
		// The row a click chose takes the keyboard, so the arrow keys go on from it.
		c.Canvas().RequestFocus(t.view.RowID(i))
		c.After(func() {
			t.selected = n
			switch {
			case !n.dir:
				a.activateTreeNode(p, n)
			case !repeated:
				a.toggleFolder(p, n)
			}
		})
	}

}

// syncTreeSelection hands the model's selection to the Tree (it is the row Tab reaches) and
// scrolls a row to show to the middle of the view when it is out of view. The selection
// follows the keyboard: the row the arrow keys moved the focus to is the selected one.
func (a *App) syncTreeSelection(canvas *gfx.Canvas, t *fileTree) {
	if focused := canvas.Focused(); !focused.IsZero() {
		for i, n := range t.rows {
			if t.view.RowID(i) == focused {
				t.selected = n
				break
			}
		}
	}
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
			t.focusNode = n
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
		// Every row starts after the room of a chevron, which a row without one keeps empty.
		row := float32(n.depth*treelist.Indent) + treeChevron + treelist.Icon + treelist.Gap + canvas.TextWidthWeight(n.name, font, weight) + treelist.Trailing
		width = max(width, row)
	}
	t.measureDirty, t.measureFont = false, font
	return width + treeScrollPad
}

// drawTreeContent declares what a row of the tree shows after its chevron: the node's icon and
// its name, the root's in bold. Viva's Tree starts a row without a chevron (a file, an empty
// folder) where the chevron of a folder at its depth is, so such a row keeps the chevron's
// room empty, and its icon lines up with the icons of the folders beside it.
func (a *App) drawTreeContent(c ui.C, p *project, n *treeNode) {
	content := func() {
		icon := fileicons.ForFile(n.name, a.colors.Dark)
		if n.dir {
			icon = fileicons.ForDirectory(n.name, a.colors.Dark)
		}
		ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		name := ui.Text(c, n.name).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
		if n == p.tree.root {
			name.Bold()
		}
		a.projectTreeMenu(c, p, n, name)
	}
	if n.dir && !n.empty {
		content()
		return
	}
	ui.Row(c).Shrink(0).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron).Children(content)
}

// focusTreeRow gives the keyboard to the row the locate button brought into view, once the row
// is declared, so the arrow keys go on from the file the editor shows.
func (a *App) focusTreeRow(canvas *gfx.Canvas, t *fileTree) {
	n := t.focusNode
	if n == nil {
		return
	}
	for i, row := range t.rows {
		if row != n {
			continue
		}
		if first, last := t.view.Visible(); i >= first && i <= last {
			canvas.RequestFrame()
			canvas.RequestFocus(t.view.RowID(i))
			t.focusNode = nil
		}
		return
	}
	t.focusNode = nil
}

// areaHook is the draw hook that notes where the tree was laid out, for the sideways wheel.
func (t *fileTree) areaHook() func(*ui.DrawContext) {
	if t.areaDraw == nil {
		t.areaDraw = func(d *ui.DrawContext) { t.area = d.Rect }
	}
	return t.areaDraw
}

// wheel scrolls the rows sideways, by a sideways swipe or the wheel with Shift held over the
// tree, and reports whether it did. Viva's Tree lays its rows out RowWidth wide but, unlike
// its List, does not take the sideways wheel itself (vivaui/viva#203); the page leaves such
// an event to the window's OnScroll, which comes here.
func (t *fileTree) wheel(event gfx.ScrollEvent) gfx.EventResult {
	if t.area.Width <= 0 || event.X < t.area.X || event.X >= t.area.Right() || event.Y < t.area.Y || event.Y >= t.area.Bottom() {
		return gfx.EventResult{}
	}
	dx := event.DeltaX
	if dx == 0 && event.Modifiers&gfx.ModifierShift != 0 {
		dx = event.DeltaY
	}
	if dx == 0 {
		return gfx.EventResult{}
	}
	if !event.Precise && dx > -treelist.RowHeight && dx < treelist.RowHeight {
		dx = treelist.RowHeight
		if event.DeltaX < 0 || event.DeltaX == 0 && event.DeltaY < 0 {
			dx = -dx
		}
	}
	t.view.ScrollToX(t.view.ScrollX() + dx)
	t.wake()
	return gfx.EventResult{Handled: true, Repaint: true}
}
