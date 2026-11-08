package workbench

import (
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
)

// Sizes of the editor's tab groups and of the places a dragged tab can land in.
const (
	// editorGroupMinWidth and editorGroupMinHeight are the least width and height a group
	// keeps when its split is dragged or the window shrinks. They are also the minimums of
	// the splitter, so the two limits agree and Viva never has to move a position the
	// workbench chose.
	editorGroupMinWidth  = 160
	editorGroupMinHeight = 96
	// splitBand is how close to an edge of a group the pointer must be, as a share of the
	// group's width or height, for a dropped tab to split the group on that side. Inside
	// it the tab joins the group.
	splitBand = 0.25
	// tabMarkInset keeps the insertion line off the top and the bottom of its strip.
	tabMarkInset = 4
)

// editorSplits identifies the splitters between the editor's groups:
// editorSplits.At(n) is the splitter of the container node with id n.
var editorSplits = tree.Sub(shellPage, tree.Name("editor-splits"))

// edge is a side of a group, which is where a dropped tab splits it.
type edge uint8

const (
	edgeNone edge = iota
	edgeLeft
	edgeRight
	edgeTop
	edgeBottom
)

// sideBySide says the edge splits the group into a left half and a right half; the top and
// bottom edges split it into an upper and a lower one.
func (e edge) sideBySide() bool { return e == edgeLeft || e == edgeRight }

// leading says the new group goes before the old one: to its left or above it.
func (e edge) leading() bool { return e == edgeLeft || e == edgeTop }

// splitNode is a node of the tree that divides the editor area among its groups. A leaf
// shows one group; a container lays out two children side by side or one over the other
// with a splitter between them, and the children may be containers in turn.
//
// A node is never copied once it has been drawn, because Viva keeps a pointer to the state
// of its splitter. The methods accept a nil node as the empty tree.
type splitNode struct {
	// id identifies the splitter of a container (see editorSplits). A leaf has none.
	id int
	// group is the tab group a leaf shows. It is empty on a container, which is how the
	// two are told apart.
	group string
	// row says a container puts its children side by side; otherwise the first is over the
	// second.
	row bool
	// ratio is the share of the container's extent the first child takes, from 0 to 1. It
	// is kept as a share rather than a size so that a resized window resizes both children
	// in proportion; only a drag of the splitter changes it.
	ratio float32
	// first and second are the children of a container.
	first, second *splitNode
	// state is the splitter between the children. Its Pos is the size of the first child,
	// which is what a drag measures from (see settle).
	state flex.SplitterState
	// extent is the container's extent along its axis in the last frame, which turns a
	// position the keyboard gave the splitter into a ratio before the next frame.
	extent float32
}

// newLeaf is a tree that shows one group.
func newLeaf(group string) *splitNode { return &splitNode{group: group} }

// leaf says the node shows a group instead of dividing its room.
func (n *splitNode) leaf() bool { return n != nil && n.group != "" }

// contains says the tree shows group.
func (n *splitNode) contains(group string) bool {
	switch {
	case n == nil:
		return false
	case n.leaf():
		return n.group == group
	}
	return n.first.contains(group) || n.second.contains(group)
}

// splitLeaf returns root with the leaf that shows target replaced by a container that
// holds it and a new leaf for added, on the side e names: a leading edge puts the new group
// first. The container is given id and starts divided in half. The tree is edited in
// place, so the splitters of the nodes that stay keep their state; a root that does not
// show target is returned as it is.
func splitLeaf(root *splitNode, target, added string, e edge, id int) *splitNode {
	switch {
	case root == nil:
		return nil
	case root.leaf():
		if root.group != target {
			return root
		}
		fresh := newLeaf(added)
		parent := &splitNode{id: id, row: e.sideBySide(), ratio: 0.5}
		if e.leading() {
			parent.first, parent.second = fresh, root
		} else {
			parent.first, parent.second = root, fresh
		}
		return parent
	}
	root.first = splitLeaf(root.first, target, added, e, id)
	root.second = splitLeaf(root.second, target, added, e, id)
	return root
}

// removeLeaf returns root without the leaf that shows group. The container that held it is
// replaced by its other child, which then takes the whole room, as a split closes when its
// last tab leaves. Removing the only leaf leaves no tree.
func removeLeaf(root *splitNode, group string) *splitNode {
	switch {
	case root == nil:
		return nil
	case root.leaf():
		if root.group == group {
			return nil
		}
		return root
	}
	root.first = removeLeaf(root.first, group)
	root.second = removeLeaf(root.second, group)
	switch {
	case root.first == nil:
		return root.second
	case root.second == nil:
		return root.first
	}
	return root
}

// settle reconciles a container with the frame that was just laid out. container and first
// are the rectangles of the container and of its first child.
//
// While the splitter is dragged, Viva has moved its Pos and the share follows it. Otherwise
// the share decides the sizes, and Pos is set to the size the first child really got, held
// inside the limits Viva measures (the same bounds as its splitLimits). Pos is then always
// where the next press will start from, and Viva never finds it out of range, which would
// make it ask for another frame.
func (n *splitNode) settle(container, first ui.Rect) {
	extent, size, least := container.Height, first.Height, float32(editorGroupMinHeight)
	if n.row {
		extent, size, least = container.Width, first.Width, editorGroupMinWidth
	}
	if extent <= 0 {
		return
	}
	n.extent = extent
	if n.state.Dragging() {
		n.ratio = shellClamp(n.state.Pos/extent, 0, 1)
		return
	}
	n.state.Pos = shellClamp(size, least, max(extent-shellSplitter-least, least))
}

// tabSlot is where the chip of one terminal's tab was laid out.
type tabSlot struct {
	term int
	rect ui.Rect
}

// dropPlace is one tab group as the last frame laid it out: where its strip of tabs and its
// body are, and where each tab is. It is what a drag is aimed against.
type dropPlace struct {
	group string
	// tool says the place is the Terminal tool window, which a tab can join but not split.
	tool        bool
	strip, body ui.Rect
	tabs        []tabSlot
}

// has says the dragged terminal is one of the tabs of the place.
func (p dropPlace) has(dragged int) bool {
	for _, t := range p.tabs {
		if t.term == dragged {
			return true
		}
	}
	return false
}

// others are the tabs of the place except the dragged one. The dragged tab is not counted,
// so moving it by less than its own width does not make it jump.
func (p dropPlace) others(dragged int) []tabSlot {
	others := make([]tabSlot, 0, len(p.tabs))
	for _, t := range p.tabs {
		if t.term != dragged {
			others = append(others, t)
		}
	}
	return others
}

// solo says the dragged terminal is the only tab of the place, so there is nothing to
// reorder it against and dropping it anywhere in the place would change nothing.
func (p dropPlace) solo(dragged int) bool { return len(p.tabs) == 1 && p.has(dragged) }

// dropKind is what dropping a tab would do.
type dropKind uint8

const (
	// dropNone is a place a tab cannot go; releasing there cancels the drag.
	dropNone dropKind = iota
	// dropJoin puts the tab into a group at an index of its strip.
	dropJoin
	// dropSplit puts the tab into a new group beside an existing one.
	dropSplit
	// dropEmpty puts the tab into the first group of an editor that has none.
	dropEmpty
)

// dropTarget is the place a dragged tab would land if it were released now.
type dropTarget struct {
	kind  dropKind
	group string
	// edge is the side of group that is split, for dropSplit.
	edge edge
	// index is the place among the group's other tabs, for dropJoin; the tab ends up at
	// this index of the group.
	index int
	// preview is the area the drop would fill, in window coordinates, and line the
	// insertion line when hasLine says there is one.
	preview ui.Rect
	line    ui.Rect
	hasLine bool
}

// dropAt finds where releasing the terminal dragged at (x, y) would put it.
//
// In a group's strip the tab joins the group at the place among the tabs the pointer is
// at. Over a group's body, near an edge, the tab splits the group on that side; anywhere
// else in the body it joins the group at the end. The Terminal tool window never splits.
// A place whose only tab is the dragged one accepts nothing, and neither does the middle of
// the dragged tab's own group. Over an editor with no group the tab opens the first one.
func dropAt(places []dropPlace, empty ui.Rect, dragged int, x, y float32) dropTarget {
	for _, p := range places {
		inStrip, inBody := pointInRect(p.strip, x, y), pointInRect(p.body, x, y)
		if !inStrip && !inBody {
			continue
		}
		if p.solo(dragged) {
			return dropTarget{}
		}
		others := p.others(dragged)
		if inStrip {
			index := insertionIndex(others, x)
			return dropTarget{
				kind: dropJoin, group: p.group, index: index, preview: p.strip,
				line: insertionMark(p.strip, others, index), hasLine: true,
			}
		}
		if !p.tool {
			if e := splitEdgeAt(p.body, x, y); e != edgeNone {
				return dropTarget{kind: dropSplit, group: p.group, edge: e, preview: edgePreview(p.body, e)}
			}
		}
		if p.has(dragged) {
			return dropTarget{}
		}
		return dropTarget{kind: dropJoin, group: p.group, index: len(others), preview: unionRect(p.strip, p.body)}
	}
	if pointInRect(empty, x, y) {
		return dropTarget{kind: dropEmpty, preview: empty}
	}
	return dropTarget{}
}

// insertionIndex is the place a tab dragged to x would take among others, the tabs of the
// strip without the dragged one: in front of the first whose middle is past x, or last.
func insertionIndex(others []tabSlot, x float32) int {
	index := 0
	for _, t := range others {
		if x >= t.rect.X+t.rect.Width/2 {
			index++
		}
	}
	return index
}

// insertionMark is the line that shows where a tab dragged to place index among others
// would stand: in the middle of the gap in front of the tab it precedes, or after the last
// one. It runs along the strip's height, like the line of a dragged tool button, and
// stays inside the strip.
func insertionMark(strip ui.Rect, others []tabSlot, index int) ui.Rect {
	x := strip.X + dragMarkLead
	switch {
	case len(others) == 0:
	case index < len(others):
		x = others[max(index, 0)].rect.X - (chromeGap+dragMark)/2
	default:
		x = others[len(others)-1].rect.Right() + (chromeGap-dragMark)/2
	}
	x = min(max(x, strip.X), strip.Right()-dragMark)
	return ui.Rect{X: x, Y: strip.Y + tabMarkInset, Width: dragMark, Height: max(strip.Height-2*tabMarkInset, 0)}
}

// splitEdgeAt is the edge of body the point (x, y) is within splitBand of, as a share of
// the body's width for the sides and of its height for the top and bottom. The nearest edge
// wins; a tie goes to the first of left, right, top and bottom. It is edgeNone for a point
// in the middle, and for a body with no area.
func splitEdgeAt(body ui.Rect, x, y float32) edge {
	if body.Width <= 0 || body.Height <= 0 {
		return edgeNone
	}
	best, nearest := edgeNone, float32(splitBand)
	for _, c := range [...]struct {
		e        edge
		distance float32
	}{
		{edgeLeft, (x - body.X) / body.Width},
		{edgeRight, (body.Right() - x) / body.Width},
		{edgeTop, (y - body.Y) / body.Height},
		{edgeBottom, (body.Bottom() - y) / body.Height},
	} {
		if c.distance < nearest {
			best, nearest = c.e, c.distance
		}
	}
	return best
}

// edgePreview is the half of body that a tab split off on edge e would fill.
func edgePreview(body ui.Rect, e edge) ui.Rect {
	halfW, halfH := body.Width/2, body.Height/2
	switch e {
	case edgeLeft:
		body.Width = halfW
	case edgeRight:
		body.X += halfW
		body.Width = halfW
	case edgeTop:
		body.Height = halfH
	case edgeBottom:
		body.Y += halfH
		body.Height = halfH
	}
	return body
}

// unionRect is the smallest rectangle that holds both a and b; a rectangle with no area
// does not count.
func unionRect(a, b ui.Rect) ui.Rect {
	if a.Width <= 0 || a.Height <= 0 {
		return b
	}
	if b.Width <= 0 || b.Height <= 0 {
		return a
	}
	x, y := min(a.X, b.X), min(a.Y, b.Y)
	return ui.Rect{X: x, Y: y, Width: max(a.Right(), b.Right()) - x, Height: max(a.Bottom(), b.Bottom()) - y}
}

// pointInRect says (x, y) is inside r. The far edges are outside, so two neighbours never
// both contain a point on their border, and a rectangle with no area contains nothing.
func pointInRect(r ui.Rect, x, y float32) bool {
	return r.Width > 0 && r.Height > 0 && x >= r.X && x < r.Right() && y >= r.Y && y < r.Bottom()
}

// drawEditorGroups declares the editor area as its tree of groups and reports whether
// there is one. With no tree the editor is empty, and drawShellEditor declares what an
// empty editor shows instead.
func (a *App) drawEditorGroups(f *flex.Frame) bool {
	p := a.project
	if p == nil || p.terms.layout == nil {
		return false
	}
	a.drawEditorNode(f, p.terms.layout).Fill()
	return true
}

// drawEditorNode declares a node of the editor's tree: a group for a leaf, or for a
// container its two children with a splitter between them. The splitter is declared right
// after the first child and before the second, as Viva wants.
//
// The first child is sized as a share of the container and may give way, down to the least
// size of a group, when the share leaves too little for the second; the second child fills
// what is left. So a window resized in either direction keeps the proportion, and a share
// that was chosen in a larger window never pushes the second child out of a smaller one.
// The splitter's own limits are the same minimums. What the layout gave the first child is
// handed to settle once the frame is laid out.
func (a *App) drawEditorNode(f *flex.Frame, n *splitNode) flex.Box {
	if n.leaf() {
		return a.drawEditorGroup(f, n.group)
	}
	least := float32(editorGroupMinHeight)
	declare := f.Column
	if n.row {
		least = editorGroupMinWidth
		declare = f.Row
	}
	var first, second flex.Box
	container := declare().Clip().Children(func() {
		first = a.drawEditorNode(f, n.first)
		f.Splitter(editorSplits.At(n.id), &n.state).Mins(least, least).Label(a.text.Panel.Resize)
		second = a.drawEditorNode(f, n.second)
	})
	share := shellClamp(n.ratio, 0, 1) * 100
	if n.row {
		first.WidthPercent(share).FillHeight().MinWidth(least).Shrink(1)
		second.Fill().MinWidth(least)
	} else {
		first.HeightPercent(share).FillWidth().MinHeight(least).Shrink(1)
		second.Fill().MinHeight(least)
	}
	u := &a.term
	u.splits = append(u.splits, splitDraw{node: n, container: container, first: first})
	return container
}

// drawEditorGroup declares one group of the editor: a strip of its terminals' tabs over a
// body that the selected terminal is painted into after the frame is laid out (see
// paintTerminal). The group is recorded for the drag, which aims at the strip and the body.
// A group that shows an open file ends its strip with the soft wrap switch.
func (a *App) drawEditorGroup(f *flex.Frame, id string) flex.Box {
	u := &a.term
	decl := groupDecl{id: id}
	decl.selected = a.project.terms.selected(id)
	decl.doc = a.project.selectedDocument(id)
	group := f.Column().Background(a.colors.Editor).Clip()
	group.Children(func() {
		decl.strip = f.Row().FillWidth().Height(panelHeaderHeight).Shrink(0).Items(flex.Center).
			Gap(chromeGap).PadX(chromeGap).Background(a.colors.Panel).Clip()
		decl.stripSet = true
		decl.strip.Children(func() {
			// The tabs fill the strip and give up their room before the switch does, so it
			// stays at the strip's end however many files are open.
			f.Row().Fill().Items(flex.Center).Gap(chromeGap).Clip().Children(func() {
				decl.tabs = a.drawTerminalChips(f, id)
			})
			if decl.doc != nil {
				a.drawSoftWrapSwitch(f, decl.doc.id)
			}
		})
		decl.body = f.Row().Fill()
		decl.bodySet = true
	})
	u.groups = append(u.groups, decl)
	return group
}

// drawSoftWrapSwitch declares the switch that turns soft wrapping of the open files on and
// off, at the end of the strip of the group that shows document doc. It looks pressed while
// wrapping is on. The click takes effect in this frame's paint, which sets every view it
// paints to the new state.
func (a *App) drawSoftWrapSwitch(f *flex.Frame, doc int) {
	on := a.softWrap
	button := f.Row().Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(docWrap.At(doc), a.text.Editor.SoftWrap, ui.HitOptions{Role: ui.RoleSwitch, Checked: on, Cursor: ui.PointerCursorHand}).
		Pressed(flex.Look{}.Background(a.colors.Active))
	icon := a.colors.Subtle
	if on {
		button = button.Background(a.colors.Active)
		icon = a.colors.Text
	} else {
		button = button.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		f.Icon(icons.WrapText).Size(shellIconSize, shellIconSize).Color(icon).
			StateFrom(button).Hover(flex.Look{}.Color(a.colors.Text))
	})
	if button.Clicked() {
		a.softWrap = !on
	}
}

// declareEmptyEditor records the box of the editor while it has no group, which is the area
// a tab can be dropped into to open the first one.
func (a *App) declareEmptyEditor(editor flex.Box) {
	a.term.empty, a.term.emptyDrawn = editor, true
}

// editorSplitKey gives a key press to the splitters of the editor's split tree the last
// frame declared; only the one that has the keyboard focus acts on it. The position the
// key gave it becomes the split's ratio at once, since the next frame lays the children
// out by the ratio.
func (a *App) editorSplitKey(event ui.KeyEvent) ui.EventResult {
	for _, s := range a.term.splits {
		n := s.node
		if result := n.state.Key(event); result.Handled {
			if n.extent > 0 {
				n.ratio = shellClamp(n.state.Pos/n.extent, 0, 1)
			}
			return result
		}
	}
	return ui.EventResult{}
}
