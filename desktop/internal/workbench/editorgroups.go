package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
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

// edge is a side of a group, which is where a dropped tab splits it; edgeNone is no side.
type edge = core.EditorEdge

const (
	edgeNone   edge = ""
	edgeLeft        = core.EditorEdgeLeft
	edgeRight       = core.EditorEdgeRight
	edgeTop         = core.EditorEdgeTop
	edgeBottom      = core.EditorEdgeBottom
)

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
	// first and second are the children of a container.
	first, second *splitNode
	// state is the splitter between the children. Its Ratio is the share of the container's
	// extent the first child takes, kept so that a resized window resizes both children in
	// proportion; only a drag of the splitter changes it.
	state ui.SplitterState
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

// layoutShape is the shape of the tree the kernel reduces: groups by name and containers by id.
func layoutShape(n *splitNode) *core.EditorLayout {
	switch {
	case n == nil:
		return nil
	case n.leaf():
		return &core.EditorLayout{Group: n.group}
	}
	return &core.EditorLayout{Node: n.id, Row: n.row, First: layoutShape(n.first), Second: layoutShape(n.second)}
}

// adoptLayout is the tree of shape, the kernel's answer, built from the nodes of old: a container
// whose id old has is that node, so its splitter keeps its state and the pointer Viva holds, and
// a leaf whose group old shows is that leaf. A container the kernel made starts divided in half.
func adoptLayout(old *splitNode, shape *core.EditorLayout) *splitNode {
	containers, leaves := map[int]*splitNode{}, map[string]*splitNode{}
	var index func(*splitNode)
	index = func(n *splitNode) {
		switch {
		case n == nil:
		case n.leaf():
			leaves[n.group] = n
		default:
			containers[n.id] = n
			index(n.first)
			index(n.second)
		}
	}
	index(old)
	var build func(*core.EditorLayout) *splitNode
	build = func(s *core.EditorLayout) *splitNode {
		switch {
		case s == nil:
			return nil
		case s.Group != "":
			if n := leaves[s.Group]; n != nil {
				return n
			}
			return newLeaf(s.Group)
		}
		n := containers[s.Node]
		if n == nil {
			n = &splitNode{id: s.Node, state: ui.SplitterState{Ratio: 0.5}}
		}
		n.row, n.first, n.second = s.Row, build(s.First), build(s.Second)
		return n
	}
	return build(shape)
}

// tabSlot is where the chip of one tab, a terminal's or a file's, was laid out. member is
// the name the group lists the tab under.
type tabSlot struct {
	member string
	rect   gfx.Rect
}

// dropPlace is one tab group as the last frame laid it out: where its strip of tabs and its
// body are, and where each tab is. It is what a drag is aimed against.
type dropPlace struct {
	group       string
	strip, body gfx.Rect
	tabs        []tabSlot
}

// others are the tabs of the place except the dragged one. The dragged tab is not counted,
// so moving it by less than its own width does not make it jump.
func (p dropPlace) others(dragged string) []tabSlot {
	others := make([]tabSlot, 0, len(p.tabs))
	for _, t := range p.tabs {
		if t.member != dragged {
			others = append(others, t)
		}
	}
	return others
}

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
	preview gfx.Rect
	line    gfx.Rect
	hasLine bool
}

// place is the target as the kernel's drop place, and false for dropNone.
func (t dropTarget) place() (core.EditorDropPlace, bool) {
	switch t.kind {
	case dropJoin:
		return core.JoinEditorGroup(t.group, t.index), true
	case dropSplit:
		return core.SplitEditorGroup(t.group, t.edge), true
	case dropEmpty:
		return core.EmptyEditorArea(), true
	}
	return core.EditorDropPlace{}, false
}

// dropAt finds where releasing the tab dragged at (x, y), the group member dragged, would
// put it, among the places rules accepts; the kernel said once, as the drag started, which
// places of each group take the tab (core.EditorDropTargets), and nil rules accept nothing.
//
// In a group's strip the tab joins the group at the place among the tabs the pointer is
// at. Over a group's body, near an edge, the tab splits the group on that side; anywhere
// else in the body it joins the group at the end. A place the rules refuse is no place, and
// so is the editor with no group unless the rules let the tab open the first one.
func dropAt(places []dropPlace, rules *core.EditorDropRules, empty gfx.Rect, dragged string, x, y float32) dropTarget {
	if rules == nil {
		return dropTarget{}
	}
	for _, p := range places {
		inStrip, inBody := pointInRect(p.strip, x, y), pointInRect(p.body, x, y)
		if !inStrip && !inBody {
			continue
		}
		r := rules.For(p.group)
		others := p.others(dragged)
		switch {
		case inStrip && r.Join:
			index := insertionIndex(others, x, y)
			return dropTarget{
				kind: dropJoin, group: p.group, index: index, preview: p.strip,
				line: insertionMark(p.strip, others, index, y), hasLine: true,
			}
		case inStrip:
			return dropTarget{}
		}
		if e := splitEdgeAt(p.body, x, y); r.Split && e != edgeNone {
			return dropTarget{kind: dropSplit, group: p.group, edge: e, preview: edgePreview(p.body, e)}
		}
		if !r.Append {
			return dropTarget{}
		}
		return dropTarget{kind: dropJoin, group: p.group, index: len(others), preview: unionRect(p.strip, p.body)}
	}
	if rules.Empty && pointInRect(empty, x, y) {
		return dropTarget{kind: dropEmpty, preview: empty}
	}
	return dropTarget{}
}

// insertionIndex is the place a tab dragged to (x, y) would take among others, the tabs of
// the strip without the dragged one, in order. A strip whose tabs wrap onto several rows has
// a row of panelHeaderHeight around each tab's middle: the dragged tab goes after every tab
// of the rows above the pointer, and on the pointer's own row in front of the first tab
// whose middle is past x. On a strip of one row that is in front of the first tab whose
// middle is past x, or last.
func insertionIndex(others []tabSlot, x, y float32) int {
	index := 0
	for _, t := range others {
		mid := t.rect.Y + t.rect.Height/2
		switch {
		case y >= mid+panelHeaderHeight/2:
			index++
		case y >= mid-panelHeaderHeight/2 && x >= t.rect.X+t.rect.Width/2:
			index++
		}
	}
	return index
}

// sameTabRow says the point at height y is on the row of the strip that holds the tab at r.
func sameTabRow(r gfx.Rect, y float32) bool {
	mid := r.Y + r.Height/2
	return y >= mid-panelHeaderHeight/2 && y < mid+panelHeaderHeight/2
}

// insertionMark is the line that shows where a tab dragged to place index among others
// would stand, the pointer being at height y: in the middle of the gap in front of the tab
// it precedes, or after the tab it follows when that one ends the pointer's row or the
// strip. It runs along the height of the row it is on, like the line of a dragged tool
// button, and stays inside the strip.
func insertionMark(strip gfx.Rect, others []tabSlot, index int, y float32) gfx.Rect {
	x, top := strip.X+dragMarkLead, strip.Y
	switch {
	case len(others) == 0:
	case index < len(others) && (index <= 0 || sameTabRow(others[index].rect, y)):
		r := others[max(index, 0)].rect
		x, top = r.X-(chromeGap+dragMark)/2, r.Y+r.Height/2-panelHeaderHeight/2
	default:
		r := others[min(index, len(others))-1].rect
		x, top = r.Right()+(chromeGap-dragMark)/2, r.Y+r.Height/2-panelHeaderHeight/2
	}
	row := min(float32(panelHeaderHeight), strip.Height)
	top = min(max(top, strip.Y), strip.Bottom()-row)
	x = min(max(x, strip.X), strip.Right()-dragMark)
	return gfx.Rect{X: x, Y: top + tabMarkInset, Width: dragMark, Height: max(row-2*tabMarkInset, 0)}
}

// splitEdgeAt is the edge of body the point (x, y) is within splitBand of, as a share of
// the body's width for the sides and of its height for the top and bottom. The nearest edge
// wins; a tie goes to the first of left, right, top and bottom. It is edgeNone for a point
// in the middle, and for a body with no area.
func splitEdgeAt(body gfx.Rect, x, y float32) edge {
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
func edgePreview(body gfx.Rect, e edge) gfx.Rect {
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
func unionRect(a, b gfx.Rect) gfx.Rect {
	if a.Width <= 0 || a.Height <= 0 {
		return b
	}
	if b.Width <= 0 || b.Height <= 0 {
		return a
	}
	x, y := min(a.X, b.X), min(a.Y, b.Y)
	return gfx.Rect{X: x, Y: y, Width: max(a.Right(), b.Right()) - x, Height: max(a.Bottom(), b.Bottom()) - y}
}

// pointInRect says (x, y) is inside r. The far edges are outside, so two neighbours never
// both contain a point on their border, and a rectangle with no area contains nothing.
func pointInRect(r gfx.Rect, x, y float32) bool {
	return r.Width > 0 && r.Height > 0 && x >= r.X && x < r.Right() && y >= r.Y && y < r.Bottom()
}

// firstEditorGroup is the first group of the layout, the one a new group is split from.
func firstEditorGroup(n *splitNode) string {
	for n != nil && !n.leaf() {
		n = n.first
	}
	if n == nil {
		return ""
	}
	return n.group
}
