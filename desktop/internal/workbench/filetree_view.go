package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/components"
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
	selected := t.marked[n.path]
	if len(t.marked) == 0 && t.anchor == "" {
		selected = n == t.selected
	}
	return ui.TreeNode{Depth: n.depth, Branch: n.dir && !n.empty, Expanded: n.dir && n.expanded, Selected: selected}
}

// projectTree declares the body of the Project tool window: the rows of the project's
// folders and files, nested under the folders that are expanded. The root is listed the first
// time the tree is shown.
func (a *App) projectTree(c ui.C, p *project) {
	t := &p.tree
	t.rowRefs = map[gfx.ID]treeRowRef{}
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
		t.rowsDirty = true
		a.listTree(p, "")
	}
	switch {
	case t.failed != "":
		ui.Column(c).Fill().Center().Gap(8).Children(func() {
			ui.Paragraph(c, a.text.Project.Failed(t.failed), 3).FillWidth().TextCenter().Color(a.colors.Subtle)
			if ui.Button(c, i18n.Shared(a.language(), "ui.retry")).Outline().Clicked() {
				c.After(func() { a.retryProjectTree(p) })
			}
		})
		return
	case !t.root.listed:
		a.panelMessage(c, a.text.Project.Loading, a.colors.Subtle)
		return
	}
	// Core lays the loaded rows out again only after the shape of the tree changed; the Tree
	// declares only the viewport and a little beyond it, and opening a folder never enumerates
	// what is under it.
	if t.rowsDirty {
		a.refreshTreeRows(p, nil)
	}
	a.syncTreeSelection(c.Canvas(), t)
	t.view.RowWidth = a.measureTree(c.Canvas(), t)
	// Names are never cut short: the rows are as wide as the widest one, and the tree
	// scrolls sideways to show the rest of it.
	// IDEA's own disclosure arrows: filled 16 point geometry in the row's existing slot,
	// so only the arrow changes and no row moves.
	t.view.Disclosure = &components.TreeDisclosure{
		Collapsed: fileicons.TreeChevron(false, a.colors.Dark),
		Expanded:  fileicons.TreeChevron(true, a.colors.Dark),
		Size:      16,
	}
	tree := ui.Tree(c, &t.view, len(t.rows), t.label, func(i int) {
		a.drawTreeContent(c, p, t.view.RowID(i), t.rows[i])
	}).Scrollbars().Grow(1).FillWidth().PadY(treelist.PadY)
	if a.elementShortcut(tree, shortcuts.OpenSelected) {
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
		if clicked && info.Modifiers&(ui.Primary|gfx.ModifierShift) != 0 {
			mods := info.Modifiers
			c.After(func() { a.treeModifiedClick(p, n, mods) })
		} else {
			c.After(func() {
				if !clicked {
					t.selected = n
				} else if !a.reduceTreeSelection(p, core.ChooseRow(n.path)) {
					return
				}
				switch {
				case !n.dir:
					a.activateTreeNode(p, n)
				case !repeated:
					a.toggleFolder(p, n)
				}
			})
		}
	}

}

// syncTreeSelection hands the model's selection to the Tree (it is the row Tab reaches) and
// scrolls a row to show to the middle of the view when it is out of view. The selection
// follows the keyboard: the row the arrow keys moved the focus to is the selected one.
func (a *App) syncTreeSelection(canvas *gfx.Canvas, t *fileTree) {
	focused := canvas.Focused()
	focusChanged := focused != t.focused
	t.focused = focused
	// A row added since the previous paint can also have a zero ID.
	if focusChanged && !focused.IsZero() {
		if _, pointer := canvas.PointerOn(focused); !pointer {
			for i, n := range t.rows {
				if t.view.RowID(i) == focused {
					t.selected = n
					break
				}
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

func (t *fileTree) isModuleRoot(n *treeNode) bool {
	_, module := t.moduleRoots[n.path]
	return n.dir && module
}

func (t *fileTree) rowWeight(n *treeNode) float32 {
	if t.isModuleRoot(n) {
		return gfx.WeightBold
	}
	if n == t.root {
		return gfx.WeightSemibold
	}
	return gfx.WeightRegular
}

// measureTree is how wide the widest row is: the width the rows are given so that every name
// shows whole. It is measured again only when the rows, their weights, or the font change.
func (a *App) measureTree(canvas *gfx.Canvas, t *fileTree) float32 {
	font := float32(treeFontSize)
	if !t.measureDirty && t.measureFont == font {
		return t.view.RowWidth
	}
	width := float32(0)
	for _, n := range t.rows {
		// Every row starts after the room of a chevron, which a row without one keeps empty.
		row := float32(n.depth*treelist.Indent) + treeChevron + treelist.Icon + treelist.Gap + canvas.TextWidthWeight(n.name, font, t.rowWeight(n)) + treelist.Trailing
		width = max(width, row)
	}
	t.measureDirty, t.measureFont = false, font
	return width + treeScrollPad
}

// drawTreeContent declares what a row shows after its chevron: the node's icon and the name
// that labels the row and carries its context menu. Viva's Tree
// starts a row without a chevron (a file, an empty folder) where the chevron of a folder at its
// depth is, so such a row keeps the chevron's room empty, and its icon lines up with the icons
// of the folders beside it.
func (a *App) drawTreeContent(c ui.C, p *project, row gfx.ID, n *treeNode) {
	entry, hasMeta := p.indexing.presentation[n.path]
	content := func() {
		var icon gfx.Icon
		iconTint := a.colors.Subtle
		switch {
		case n.dir && hasMeta && (entry.Role != "plain" || entry.Color != ""):
			icon = a.directoryIconFor(p, entry.Icon)
			if tinted, ok := parseHexColor(entry.Color, 0xff); ok {
				iconTint = tinted
			}
		case p.tree.isModuleRoot(n):
			icon = fileicons.ForBuildNode(fileicons.BuildProject, a.colors.Dark)
		case n.dir:
			icon = fileicons.ForDirectory(n.name, a.colors.Dark)
		default:
			icon = fileicons.ForFile(n.name, a.colors.Dark)
		}
		ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(iconTint)
		textColor := a.treeTextColor(p, n)
		if hasMeta {
			if entry.Excluded {
				textColor = a.colors.Subtle
			} else if entry.TintText && entry.Color != "" {
				if _, hasGit := p.git.tree[n.path]; !hasGit {
					if tinted, ok := parseHexColor(entry.Color, 0xff); ok {
						textColor = tinted
					}
				}
			}
		}
		name := ui.Text(c, n.name).FontSize(treeFontSize).Weight(p.tree.rowWeight(n)).Color(textColor).Shrink(0)
		if n.dir && !p.indexing.hideTags && hasMeta && entry.Tag != "" {
			tagFg := a.colors.Subtle
			tagBg := a.colors.Hover
			if tinted, ok := parseHexColor(entry.Color, 0xff); ok {
				tagFg = tinted
			}
			if bg, ok := parseHexColor(entry.Color, 34); ok {
				tagBg = bg
			}
			ui.Row(c).Shrink(0).PadSides(1, 5, 1, 5).Radius(3).Background(tagBg).Children(func() {
				ui.Text(c, entry.Tag).FontSize(11).Color(tagFg).Shrink(0)
			})
		}
		a.projectTreeMenu(c, p, row, n, name)
	}
	var bgTint gfx.Color
	hasBg := false
	if !p.indexing.hideBgTint && hasMeta && entry.BgColor != "" && n != p.tree.root {
		alpha := uint8(26)
		if a.colors.Dark {
			alpha = 34
		}
		if parsed, ok := parseHexColor(entry.BgColor, alpha); ok {
			bgTint, hasBg = parsed, true
		}
	}
	if n.dir && !n.empty {
		if hasBg {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(c.Theme().Metrics.GapItem).Radius(3).Background(bgTint).Children(content)
			return
		}
		content()
		return
	}
	r := ui.Row(c).Shrink(0).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron)
	if hasBg {
		r = r.FillWidth().Radius(3).Background(bgTint)
	}
	r.Children(content)
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
// its List, does not take the sideways wheel itself (only List registers a sideways wheel
// route; #1821 item 3); the page leaves such an event to the window's OnScroll, which comes
// here.
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
