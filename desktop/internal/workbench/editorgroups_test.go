package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// leaves lists the groups a split tree shows, in layout order: left to right and top to
// bottom.
func leaves(n *splitNode) []string {
	switch {
	case n == nil:
		return nil
	case n.leaf():
		return []string{n.group}
	}
	return append(leaves(n.first), leaves(n.second)...)
}

// threeWay is the tree "a | (b over c)": a container with id 1 that holds a and a container
// with id 2.
func threeWay(t *testing.T) *splitNode {
	t.Helper()
	root := splitLeaf(newLeaf("a"), "a", "b", edgeRight, 1)
	root = splitLeaf(root, "b", "c", edgeBottom, 2)
	if got := leaves(root); !slices.Equal(got, []string{"a", "b", "c"}) {
		t.Fatalf("leaves = %v, want [a b c]", got)
	}
	if root.second.leaf() || root.second.id != 2 || root.second.row {
		t.Fatalf("second child = %+v, want the column with id 2", root.second)
	}
	return root
}

func TestSplitLeafPutsTheNewGroupOnTheNamedSide(t *testing.T) {
	cases := []struct {
		edge edge
		row  bool
		want []string
	}{
		{edgeRight, true, []string{"a", "b"}},
		{edgeLeft, true, []string{"b", "a"}},
		{edgeBottom, false, []string{"a", "b"}},
		{edgeTop, false, []string{"b", "a"}},
	}
	for _, c := range cases {
		got := splitLeaf(newLeaf("a"), "a", "b", c.edge, 7)
		if got.leaf() || got.id != 7 || got.row != c.row || got.state.Ratio != 0.5 {
			t.Errorf("edge %d: container = %+v, want id 7, row %v, ratio 0.5", c.edge, got, c.row)
		}
		if order := leaves(got); !slices.Equal(order, c.want) {
			t.Errorf("edge %d: leaves = %v, want %v", c.edge, order, c.want)
		}
	}
}

func TestSplitLeafEditsInPlaceAndIgnoresUnknownTargets(t *testing.T) {
	root := threeWay(t)
	first, inner := root.first, root.second

	// A target the tree does not show changes nothing.
	if got := splitLeaf(root, "zzz", "d", edgeLeft, 3); got != root || !slices.Equal(leaves(got), []string{"a", "b", "c"}) {
		t.Errorf("splitting an unknown group changed the tree: %v", leaves(got))
	}
	// Splitting a leaf deep in the tree keeps every node that stays, so their splitters keep
	// their state.
	got := splitLeaf(root, "c", "d", edgeRight, 3)
	if got != root || root.first != first || root.second != inner {
		t.Errorf("splitting a leaf replaced a node that stays")
	}
	if order := leaves(got); !slices.Equal(order, []string{"a", "b", "c", "d"}) {
		t.Errorf("leaves = %v, want [a b c d]", order)
	}
	if splitLeaf(nil, "a", "b", edgeLeft, 1) != nil {
		t.Errorf("splitting no tree made one")
	}
}

func TestRemoveLeafLetsTheSiblingTakeTheRoom(t *testing.T) {
	// Removing c leaves the column's other child, b, in its place.
	root := threeWay(t)
	if got := removeLeaf(root, "c"); got != root || !root.second.leaf() || root.second.group != "b" {
		t.Errorf("after removing c: leaves = %v, second = %+v", leaves(got), root.second)
	}

	// Removing a leaves the column as the whole tree.
	root = threeWay(t)
	inner := root.second
	if got := removeLeaf(root, "a"); got != inner || !slices.Equal(leaves(got), []string{"b", "c"}) {
		t.Errorf("after removing a: leaves = %v", leaves(got))
	}

	// Removing b leaves c beside a.
	root = threeWay(t)
	if got := removeLeaf(root, "b"); got != root || !slices.Equal(leaves(got), []string{"a", "c"}) || !root.second.leaf() {
		t.Errorf("after removing b: leaves = %v", leaves(got))
	}

	// A group the tree does not show changes nothing.
	root = threeWay(t)
	if got := removeLeaf(root, "zzz"); got != root || !slices.Equal(leaves(got), []string{"a", "b", "c"}) {
		t.Errorf("removing an unknown group changed the tree: %v", leaves(got))
	}

	// The only leaf leaves no tree, and no tree stays none.
	if got := removeLeaf(newLeaf("a"), "a"); got != nil {
		t.Errorf("removing the only leaf left %+v", got)
	}
	if removeLeaf(nil, "a") != nil {
		t.Errorf("removing from no tree made one")
	}
}

func TestSplitTreeContains(t *testing.T) {
	var none *splitNode
	if none.contains("a") || none.leaf() {
		t.Errorf("no tree shows a group")
	}
	root := threeWay(t)
	for _, group := range []string{"a", "b", "c"} {
		if !root.contains(group) {
			t.Errorf("tree does not contain %q", group)
		}
	}
	if root.contains("d") {
		t.Errorf("tree contains d")
	}
	if root.leaf() {
		t.Errorf("a container is not a leaf")
	}
}

func TestSplitEdgeAt(t *testing.T) {
	// The bands are a quarter of the width, 100, and of the height, 50.
	body := gfx.Rect{X: 100, Y: 50, Width: 400, Height: 200}
	cases := []struct {
		name string
		x, y float32
		want edge
	}{
		{"middle", 300, 150, edgeNone},
		{"near the left edge", 110, 150, edgeLeft},
		{"near the right edge", 490, 150, edgeRight},
		{"near the top edge", 300, 60, edgeTop},
		{"near the bottom edge", 300, 240, edgeBottom},
		{"just inside the left band", 199, 150, edgeLeft},
		{"just outside the left band", 201, 150, edgeNone},
		// In a corner the nearer edge wins: 10/400 of the width is nearer than 10/200 of the
		// height, and 2/200 of the height is nearer than 30/400 of the width.
		{"corner nearer to the left", 110, 60, edgeLeft},
		{"corner nearer to the top", 130, 52, edgeTop},
	}
	for _, c := range cases {
		if got := splitEdgeAt(body, c.x, c.y); got != c.want {
			t.Errorf("%s: splitEdgeAt(%v, %v) = %d, want %d", c.name, c.x, c.y, got, c.want)
		}
	}

	// A tie goes to the first of left, right, top and bottom.
	square := gfx.Rect{Width: 100, Height: 100}
	if got := splitEdgeAt(square, 10, 10); got != edgeLeft {
		t.Errorf("tie of left and top = %d, want left", got)
	}
	if got := splitEdgeAt(square, 90, 10); got != edgeRight {
		t.Errorf("tie of right and top = %d, want right", got)
	}
	// A body with no area has no edge.
	if got := splitEdgeAt(gfx.Rect{}, 0, 0); got != edgeNone {
		t.Errorf("empty body = %d, want none", got)
	}
	if got := splitEdgeAt(gfx.Rect{Width: 100}, 1, 0); got != edgeNone {
		t.Errorf("body with no height = %d, want none", got)
	}
}

func TestEdgePreviewIsTheHalfOnThatSide(t *testing.T) {
	body := gfx.Rect{X: 100, Y: 50, Width: 400, Height: 200}
	cases := []struct {
		edge edge
		want gfx.Rect
	}{
		{edgeLeft, gfx.Rect{X: 100, Y: 50, Width: 200, Height: 200}},
		{edgeRight, gfx.Rect{X: 300, Y: 50, Width: 200, Height: 200}},
		{edgeTop, gfx.Rect{X: 100, Y: 50, Width: 400, Height: 100}},
		{edgeBottom, gfx.Rect{X: 100, Y: 150, Width: 400, Height: 100}},
		{edgeNone, body},
	}
	for _, c := range cases {
		if got := edgePreview(body, c.edge); got != c.want {
			t.Errorf("edgePreview(edge %d) = %v, want %v", c.edge, got, c.want)
		}
	}
}

func TestInsertionIndex(t *testing.T) {
	// Three tabs 100 wide; their middles are 50, 154 and 258.
	others := []tabSlot{
		{member: terminalMember(1), rect: gfx.Rect{X: 0, Width: 100}},
		{member: terminalMember(2), rect: gfx.Rect{X: 104, Width: 100}},
		{member: terminalMember(3), rect: gfx.Rect{X: 208, Width: 100}},
	}
	cases := []struct {
		x    float32
		want int
	}{{-10, 0}, {10, 0}, {49, 0}, {50, 1}, {120, 1}, {200, 2}, {300, 3}, {900, 3}}
	for _, c := range cases {
		if got := insertionIndex(others, c.x, 0); got != c.want {
			t.Errorf("insertionIndex(x = %v) = %d, want %d", c.x, got, c.want)
		}
	}
	if got := insertionIndex(nil, 50, 0); got != 0 {
		t.Errorf("insertionIndex with no tabs = %d, want 0", got)
	}
}

// TestInsertionIndexAcrossRows drags over a strip whose tabs wrap: two tabs on a first row
// around height 16 and one on a second row around height 48.
func TestInsertionIndexAcrossRows(t *testing.T) {
	others := []tabSlot{
		{member: terminalMember(1), rect: gfx.Rect{X: 0, Y: 4, Width: 100, Height: 24}},
		{member: terminalMember(2), rect: gfx.Rect{X: 104, Y: 4, Width: 100, Height: 24}},
		{member: terminalMember(3), rect: gfx.Rect{X: 0, Y: 36, Width: 100, Height: 24}},
	}
	cases := []struct {
		x, y float32
		want int
	}{
		{10, 0, 0}, {10, 16, 0}, {120, 16, 1}, {300, 16, 2},
		{10, 48, 2}, {60, 48, 3}, {300, 60, 3},
	}
	for _, c := range cases {
		if got := insertionIndex(others, c.x, c.y); got != c.want {
			t.Errorf("insertionIndex(%v, %v) = %d, want %d", c.x, c.y, got, c.want)
		}
	}
}

func TestInsertionMark(t *testing.T) {
	strip := gfx.Rect{X: 10, Y: 20, Width: 400, Height: 32}
	others := []tabSlot{
		{member: terminalMember(1), rect: gfx.Rect{X: 20, Y: 24, Width: 100, Height: 24}},
		{member: terminalMember(2), rect: gfx.Rect{X: 124, Y: 24, Width: 100, Height: 24}},
	}
	// The line is 2 wide and 24 high, 4 below the strip's top, and stands in the middle of
	// the 4 pixel gap between two tabs.
	cases := []struct {
		name   string
		strip  gfx.Rect
		others []tabSlot
		index  int
		want   gfx.Rect
	}{
		{"no tabs", strip, nil, 0, gfx.Rect{X: 12, Y: 24, Width: 2, Height: 24}},
		{"before the first", strip, others, 0, gfx.Rect{X: 17, Y: 24, Width: 2, Height: 24}},
		{"between the two", strip, others, 1, gfx.Rect{X: 121, Y: 24, Width: 2, Height: 24}},
		{"after the last", strip, others, 2, gfx.Rect{X: 225, Y: 24, Width: 2, Height: 24}},
		{
			"held inside the strip at the start", strip,
			[]tabSlot{{member: terminalMember(1), rect: gfx.Rect{X: 10, Y: 24, Width: 50, Height: 24}}}, 0,
			gfx.Rect{X: 10, Y: 24, Width: 2, Height: 24},
		},
		{
			"held inside the strip at the end", gfx.Rect{X: 10, Y: 20, Width: 100, Height: 32},
			[]tabSlot{{member: terminalMember(1), rect: gfx.Rect{X: 108, Y: 24, Width: 100, Height: 24}}}, 1,
			gfx.Rect{X: 108, Y: 24, Width: 2, Height: 24},
		},
	}
	for _, c := range cases {
		if got := insertionMark(c.strip, c.others, c.index, 36); got != c.want {
			t.Errorf("%s: insertionMark = %v, want %v", c.name, got, c.want)
		}
	}

	// On a strip of two rows the line stands on the pointer's row: in front of the first tab
	// of the second row while the pointer is there, and after the last tab of the first row
	// while it is at the end of the first.
	rows := gfx.Rect{X: 10, Y: 20, Width: 400, Height: 64}
	wrapped := []tabSlot{
		{member: terminalMember(1), rect: gfx.Rect{X: 20, Y: 24, Width: 100, Height: 24}},
		{member: terminalMember(2), rect: gfx.Rect{X: 20, Y: 56, Width: 100, Height: 24}},
	}
	for _, c := range []struct {
		name string
		y    float32
		want gfx.Rect
	}{
		{"second row", 68, gfx.Rect{X: 17, Y: 56, Width: 2, Height: 24}},
		{"end of the first row", 36, gfx.Rect{X: 121, Y: 24, Width: 2, Height: 24}},
	} {
		if got := insertionMark(rows, wrapped, 1, c.y); got != c.want {
			t.Errorf("%s: insertionMark = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestUnionRectAndPointInRect(t *testing.T) {
	a := gfx.Rect{X: 0, Y: 0, Width: 10, Height: 10}
	b := gfx.Rect{X: 20, Y: 5, Width: 10, Height: 10}
	if got := unionRect(a, b); got != (gfx.Rect{X: 0, Y: 0, Width: 30, Height: 15}) {
		t.Errorf("unionRect = %v, want {0 0 30 15}", got)
	}
	if got := unionRect(gfx.Rect{}, b); got != b {
		t.Errorf("a rectangle with no area changed the union: %v", got)
	}
	if got := unionRect(a, gfx.Rect{Width: 5}); got != a {
		t.Errorf("a rectangle with no height changed the union: %v", got)
	}

	// The near edges are inside and the far edges outside, so neighbours never share a point.
	cases := []struct {
		x, y float32
		want bool
	}{{0, 0, true}, {9.5, 9.5, true}, {10, 5, false}, {5, 10, false}, {-1, 5, false}, {5, -1, false}}
	for _, c := range cases {
		if got := pointInRect(a, c.x, c.y); got != c.want {
			t.Errorf("pointInRect(%v, %v) = %v, want %v", c.x, c.y, got, c.want)
		}
	}
	if pointInRect(gfx.Rect{X: 5, Y: 5}, 5, 5) {
		t.Errorf("a rectangle with no area contains a point")
	}
}

func TestDropPlaceHelpers(t *testing.T) {
	p := dropPlace{tabs: []tabSlot{{member: terminalMember(1)}, {member: terminalMember(2)}}}
	if !p.has(terminalMember(1)) || p.has(terminalMember(3)) {
		t.Errorf("has: 1 = %v, 3 = %v, want true and false", p.has(terminalMember(1)), p.has(terminalMember(3)))
	}
	if got := p.others(terminalMember(1)); len(got) != 1 || got[0].member != terminalMember(2) {
		t.Errorf("others(1) = %v, want only the tab of 2", got)
	}
	if got := p.others(terminalMember(3)); len(got) != 2 {
		t.Errorf("others(3) has %d tabs, want 2", len(got))
	}
	if p.solo(terminalMember(1)) {
		t.Errorf("a place with two tabs is not solo")
	}
	one := dropPlace{tabs: []tabSlot{{member: terminalMember(5)}}}
	if !one.solo(terminalMember(5)) || one.solo(terminalMember(6)) {
		t.Errorf("solo: 5 = %v, 6 = %v, want true and false", one.solo(terminalMember(5)), one.solo(terminalMember(6)))
	}
}

// dragFixture is the Terminal tool window at the bottom left, with the tabs of terminals 1
// and 2, and one editor group at the right, with the tabs of 3 and 4. The window is 1000
// wide and 840 high.
func dragFixture() []dropPlace {
	return []dropPlace{
		{
			group: toolGroup, tool: true,
			strip: gfx.Rect{X: 0, Y: 600, Width: 400, Height: 32},
			body:  gfx.Rect{X: 0, Y: 632, Width: 400, Height: 200},
			tabs: []tabSlot{
				{member: terminalMember(1), rect: gfx.Rect{X: 10, Y: 604, Width: 100, Height: 24}},
				{member: terminalMember(2), rect: gfx.Rect{X: 114, Y: 604, Width: 100, Height: 24}},
			},
		},
		{
			group: "editor:1",
			strip: gfx.Rect{X: 400, Y: 0, Width: 600, Height: 32},
			body:  gfx.Rect{X: 400, Y: 32, Width: 600, Height: 568},
			tabs: []tabSlot{
				{member: terminalMember(3), rect: gfx.Rect{X: 404, Y: 4, Width: 100, Height: 24}},
				{member: terminalMember(4), rect: gfx.Rect{X: 508, Y: 4, Width: 100, Height: 24}},
			},
		},
	}
}

func TestDropAtStrips(t *testing.T) {
	places := dragFixture()

	// A tab from the tool window dropped at the right end of the editor's strip joins it last.
	got := dropAt(places, gfx.Rect{}, terminalMember(1), 900, 10)
	if got.kind != dropJoin || got.group != "editor:1" || got.index != 2 || !got.hasLine || got.preview != places[1].strip {
		t.Errorf("end of the editor strip = %+v, want a join at index 2 with a line", got)
	}
	// Dropped before the middle of the first tab it goes first, and the line stands in front
	// of that tab.
	got = dropAt(places, gfx.Rect{}, terminalMember(1), 430, 10)
	if got.kind != dropJoin || got.index != 0 || got.line != (gfx.Rect{X: 401, Y: 4, Width: 2, Height: 24}) {
		t.Errorf("front of the editor strip = %+v, want a join at index 0 with its line at 401", got)
	}
	// A tab of the editor's own group dropped in its strip reorders it: the dragged tab is
	// not counted, so the only other tab, 4, is before the pointer.
	got = dropAt(places, gfx.Rect{}, terminalMember(3), 900, 10)
	if got.kind != dropJoin || got.group != "editor:1" || got.index != 1 || got.line != (gfx.Rect{X: 609, Y: 4, Width: 2, Height: 24}) {
		t.Errorf("own strip = %+v, want a join at index 1 with its line at 609", got)
	}
	// And a tab from the editor dropped in the tool window's strip joins that.
	got = dropAt(places, gfx.Rect{}, terminalMember(3), 300, 610)
	if got.kind != dropJoin || got.group != toolGroup || got.index != 2 {
		t.Errorf("tool strip = %+v, want a join of the tool window at index 2", got)
	}
}

func TestDropAtBodies(t *testing.T) {
	places := dragFixture()
	body := places[1].body

	// The middle of a group's body joins it at the end and tints the whole group.
	got := dropAt(places, gfx.Rect{}, terminalMember(1), 700, 300)
	if got.kind != dropJoin || got.group != "editor:1" || got.index != 2 || got.hasLine ||
		got.preview != (gfx.Rect{X: 400, Y: 0, Width: 600, Height: 600}) {
		t.Errorf("middle of the editor body = %+v, want a join at the end over the whole group", got)
	}
	// Near an edge of the body the tab splits the group, and the preview is that half.
	got = dropAt(places, gfx.Rect{}, terminalMember(1), 990, 300)
	if got.kind != dropSplit || got.group != "editor:1" || got.edge != edgeRight || got.preview != edgePreview(body, edgeRight) {
		t.Errorf("right of the editor body = %+v, want a split on the right", got)
	}
	// A group with other tabs can be split by its own tab.
	got = dropAt(places, gfx.Rect{}, terminalMember(3), 410, 300)
	if got.kind != dropSplit || got.group != "editor:1" || got.edge != edgeLeft {
		t.Errorf("left of its own body = %+v, want a split on the left", got)
	}
	// But the middle of its own group is nowhere to go.
	if got = dropAt(places, gfx.Rect{}, terminalMember(3), 700, 300); got.kind != dropNone {
		t.Errorf("middle of its own body = %+v, want no place", got)
	}
	// The Terminal tool window is never split: near its edge the tab joins it.
	got = dropAt(places, gfx.Rect{}, terminalMember(3), 5, 700)
	if got.kind != dropJoin || got.group != toolGroup || got.index != 2 ||
		got.preview != (gfx.Rect{X: 0, Y: 600, Width: 400, Height: 232}) {
		t.Errorf("edge of the tool body = %+v, want a join, not a split", got)
	}
	// A tool window tab dropped on its own body is nowhere to go either.
	if got = dropAt(places, gfx.Rect{}, terminalMember(1), 5, 700); got.kind != dropNone {
		t.Errorf("own tool body = %+v, want no place", got)
	}
}

func TestDropAtSoloPlaceAcceptsNothing(t *testing.T) {
	places := []dropPlace{{
		group: "editor:2",
		strip: gfx.Rect{X: 0, Y: 0, Width: 300, Height: 32},
		body:  gfx.Rect{X: 0, Y: 32, Width: 300, Height: 200},
		tabs:  []tabSlot{{member: terminalMember(5), rect: gfx.Rect{X: 4, Y: 4, Width: 100, Height: 24}}},
	}}
	for _, at := range [][2]float32{{10, 10}, {100, 100}, {2, 100}} {
		if got := dropAt(places, gfx.Rect{}, terminalMember(5), at[0], at[1]); got.kind != dropNone {
			t.Errorf("solo place at %v = %+v, want no place", at, got)
		}
	}
	// Another terminal can still be dropped into it.
	if got := dropAt(places, gfx.Rect{}, terminalMember(6), 10, 10); got.kind != dropJoin || got.index != 0 {
		t.Errorf("strip of the solo place for another terminal = %+v, want a join at 0", got)
	}
	if got := dropAt(places, gfx.Rect{}, terminalMember(6), 100, 100); got.kind != dropJoin || got.index != 1 {
		t.Errorf("body of the solo place for another terminal = %+v, want a join at 1", got)
	}
}

func TestDropAtEmptyEditorAndOutside(t *testing.T) {
	empty := gfx.Rect{X: 0, Y: 32, Width: 1000, Height: 568}
	got := dropAt(nil, empty, terminalMember(1), 500, 300)
	if got.kind != dropEmpty || got.preview != empty {
		t.Errorf("empty editor = %+v, want dropEmpty over the editor", got)
	}
	if got = dropAt(nil, empty, terminalMember(1), 500, 10); got.kind != dropNone {
		t.Errorf("above the empty editor = %+v, want no place", got)
	}
	if got = dropAt(nil, gfx.Rect{}, terminalMember(1), 0, 0); got.kind != dropNone {
		t.Errorf("no editor box = %+v, want no place", got)
	}
	// Between the tool window and the editor is no place.
	if got = dropAt(dragFixture(), gfx.Rect{}, terminalMember(1), 200, 300); got.kind != dropNone {
		t.Errorf("gap = %+v, want no place", got)
	}
}

func TestMemberAndGroupNames(t *testing.T) {
	if got := terminalMember(3); got != "terminal:3" {
		t.Errorf("terminalMember(3) = %q", got)
	}
	if got := editorGroupID(2); got != "editor:2" {
		t.Errorf("editorGroupID(2) = %q", got)
	}
	for member, want := range map[string]int{"terminal:3": 3, "terminal:12": 12} {
		if id, ok := memberTerminal(member); !ok || id != want {
			t.Errorf("memberTerminal(%q) = %d, %v, want %d, true", member, id, ok, want)
		}
	}
	for _, member := range []string{"", "terminal:", "terminal:x", "terminal:0", "terminal:-1", "editor:3", "3"} {
		if id, ok := memberTerminal(member); ok {
			t.Errorf("memberTerminal(%q) = %d, true, want false", member, id)
		}
	}
	// The name of a terminal reads back as the terminal.
	if id, ok := memberTerminal(terminalMember(41)); !ok || id != 41 {
		t.Errorf("round trip of 41 = %d, %v", id, ok)
	}
	if emptyPolicy(toolGroup) != core.KeepEmptyGroups {
		t.Errorf("the tool window's group must be kept when empty")
	}
	if emptyPolicy(editorGroupID(1)) != core.RemoveEmptyGroups {
		t.Errorf("a group of the editor must go when empty")
	}
}

func TestTerminalSetLookups(t *testing.T) {
	set := &terminalSet{list: []*terminal{{id: 1, number: 1}, {id: 2, number: 2}, {id: 5, number: 4}}}
	if got := set.find(2); got == nil || got.id != 2 {
		t.Errorf("find(2) = %+v", got)
	}
	if set.find(9) != nil {
		t.Errorf("find(9) found a terminal")
	}
	// The lowest number nobody has is handed out: 3 here.
	if got := set.freeNumber(); got != 3 {
		t.Errorf("freeNumber = %d, want 3", got)
	}
	if got := (&terminalSet{}).freeNumber(); got != 1 {
		t.Errorf("freeNumber of no terminals = %d, want 1", got)
	}

	set.bench = core.EditorWorkbench{Groups: []core.EditorGroup{
		{ID: toolGroup, Members: []string{"terminal:1", "terminal:2"}, Selected: "terminal:2"},
		{ID: "editor:1", Members: []string{"terminal:9"}, Selected: "terminal:9"},
		{ID: "editor:2"},
	}}
	if got := set.selected(toolGroup); got == nil || got.id != 2 {
		t.Errorf("selected(tool) = %+v, want terminal 2", got)
	}
	// A group that is gone, one that shows nothing, and one that shows a terminal the
	// project no longer has all show no terminal.
	for _, group := range []string{"editor:3", "editor:2", "editor:1"} {
		if got := set.selected(group); got != nil {
			t.Errorf("selected(%q) = %+v, want none", group, got)
		}
	}
}

func TestTabDragLocateStaysInsideTheWindow(t *testing.T) {
	a := &App{}
	a.term.tool, a.term.groups = groupsOf(dragFixture())
	viewport := gfx.Size{Width: 1000, Height: 840}

	if got := a.tabDragLocate(terminalMember(1), 900, 10, viewport); got.kind != dropJoin || got.group != "editor:1" {
		t.Errorf("inside the window = %+v, want a join of editor:1", got)
	}
	for _, at := range [][2]float32{{-1, 10}, {900, -1}, {1000, 10}, {900, 840}} {
		if got := a.tabDragLocate(terminalMember(1), at[0], at[1], viewport); got.kind != dropNone {
			t.Errorf("outside the window at %v = %+v, want no place", at, got)
		}
	}
}

// groupsOf makes the groups of the page's last paint that lay out as places: the tool window
// and the groups of the editor.
func groupsOf(places []dropPlace) (*groupPlace, []*groupPlace) {
	var tool *groupPlace
	var groups []*groupPlace
	for _, p := range places {
		g := newGroupPlace(p.group, p.tool)
		g.strip, g.body = p.strip, p.body
		for _, t := range p.tabs {
			g.chips = append(g.chips, tabSlotDecl{member: t.member, rect: t.rect})
		}
		if p.tool {
			tool = g
		} else {
			groups = append(groups, g)
		}
	}
	return tool, groups
}

func TestGroupPlaceReportsWhatTheLastPaintLaidOut(t *testing.T) {
	g := newGroupPlace("editor:1", false)
	if p := g.place(); p.group != "editor:1" || p.tool || p.strip != (gfx.Rect{}) || p.body != (gfx.Rect{}) || len(p.tabs) != 0 {
		t.Errorf("place of a group nothing was laid out for = %+v, want only its name", p)
	}
	g.stripHook(&ui.DrawContext{Rect: gfx.Rect{X: 1, Y: 2, Width: 3, Height: 4}})
	g.chips = append(g.chips, tabSlotDecl{member: terminalMember(5)})
	g.chipHook(0)(&ui.DrawContext{Rect: gfx.Rect{X: 9, Width: 10, Height: 11}})
	p := g.place()
	if p.strip.Width != 3 || len(p.tabs) != 1 || p.tabs[0].member != terminalMember(5) || p.tabs[0].rect.X != 9 {
		t.Errorf("place = %+v, want the strip and the tab the hooks were given", p)
	}
	if got := newGroupPlace(toolGroup, true).place(); !got.tool {
		t.Errorf("place of the tool window = %+v, want tool", got)
	}
}

func TestTerminalUIPlacesTheToolWindowFirst(t *testing.T) {
	u := terminalUI{
		tool:   newGroupPlace(toolGroup, true),
		groups: []*groupPlace{newGroupPlace("editor:1", false), newGroupPlace("editor:2", false)},
	}
	ids := func() []string {
		var ids []string
		for _, p := range u.places() {
			ids = append(ids, p.group)
		}
		return ids
	}
	if got := ids(); !slices.Equal(got, []string{toolGroup, "editor:1", "editor:2"}) {
		t.Errorf("places with the tool window = %v", got)
	}
	u.tool = nil
	if got := ids(); !slices.Equal(got, []string{"editor:1", "editor:2"}) {
		t.Errorf("places without the tool window = %v", got)
	}
}

func TestBeginTerminalFrameKeepsTheGesture(t *testing.T) {
	a := &App{}
	u := &a.term
	u.tool, u.toolDrawn, u.emptyDrawn = newGroupPlace(toolGroup, true), true, true
	u.groups = append(u.groups, newGroupPlace("editor:1", false), newGroupPlace("editor:2", false))
	u.tabIDs = append(u.tabIDs, tabID{member: terminalMember(1)})
	u.drag = tabDrag{active: true, member: terminalMember(2)}

	a.beginTerminalFrame()

	if u.tool != nil || u.toolDrawn || u.emptyDrawn || len(u.groups) != 0 || len(u.tabIDs) != 0 {
		t.Errorf("a new frame kept what the last one declared: %+v", u)
	}
	if !u.drag.active || u.drag.member != terminalMember(2) {
		t.Errorf("the drag was lost between frames: %+v", u.drag)
	}
}

// A file's tab joins, splits and reorders the editor's groups as a terminal's does, but the
// Terminal tool window takes terminals only: over it a file's tab has no place.
func TestDropAtFileTab(t *testing.T) {
	places := dragFixture()
	places[1].tabs = append(places[1].tabs, tabSlot{member: documentMember(7), rect: gfx.Rect{X: 612, Y: 4, Width: 100, Height: 24}})
	file := documentMember(7)

	// In its own strip the file is not counted, so the two terminals are before the pointer.
	if got := dropAt(places, gfx.Rect{}, file, 900, 10); got.kind != dropJoin || got.group != "editor:1" || got.index != 2 {
		t.Errorf("own strip = %+v, want a join at index 2", got)
	}
	// Before the middle of the first tab it goes first, in front of the terminals.
	if got := dropAt(places, gfx.Rect{}, file, 430, 10); got.kind != dropJoin || got.index != 0 {
		t.Errorf("front of its strip = %+v, want a join at index 0", got)
	}
	// Near an edge of its group's body it splits the group.
	if got := dropAt(places, gfx.Rect{}, file, 410, 300); got.kind != dropSplit || got.edge != edgeLeft {
		t.Errorf("left edge = %+v, want a split on the left", got)
	}
	// A terminal of the group counts the file's tab among the others.
	if got := dropAt(places, gfx.Rect{}, terminalMember(3), 990, 10); got.kind != dropJoin || got.index != 2 {
		t.Errorf("terminal at the end of a mixed strip = %+v, want a join at index 2", got)
	}
	// The Terminal tool window's strip and body take no file.
	for _, at := range [][2]float32{{300, 610}, {200, 700}} {
		if got := dropAt(places, gfx.Rect{}, file, at[0], at[1]); got.kind != dropNone {
			t.Errorf("file over the tool window at %v = %+v, want no place", at, got)
		}
	}
}

func TestTabAcceptFollowsOnlyATerminalsTab(t *testing.T) {
	a := &App{}
	a.term.tool, a.term.groups = groupsOf(dragFixture())
	if a.tabAccept(gfx.ID{}, gfx.ID{}) {
		t.Errorf("a source that is no terminal's tab was followed")
	}
	if a.term.drag.active {
		t.Errorf("drag after a foreign source = %+v, want none", a.term.drag)
	}
}

func TestTabDropDoesNothingWithoutADragAndClearsOne(t *testing.T) {
	a := &App{project: &project{}}
	a.tabDrop(gfx.ID{}, gfx.ID{})
	a.term.drag = tabDrag{active: true, member: terminalMember(1), target: dropTarget{kind: dropNone}}
	a.tabDrop(gfx.ID{}, gfx.ID{})
	if a.term.drag != (tabDrag{}) {
		t.Errorf("drag after a drop = %+v, want none", a.term.drag)
	}
}

func TestEndDragsForgetsAGestureVivaLetGoOf(t *testing.T) {
	a := &App{}
	a.drag = dragState{active: true, item: 3}
	a.term.drag = tabDrag{active: true, member: terminalMember(2)}
	a.endDrags()
	if a.drag != (dragState{}) || a.term.drag != (tabDrag{}) {
		t.Errorf("gestures after endDrags = %+v, %+v, want none", a.drag, a.term.drag)
	}
}

// A terminal's tab dragged from the Terminal tool window onto the editor joins its group, and
// dragged to the edge of a group splits it, all through the page's drag and drop.
func TestTerminalTabDragJoinsAndSplitsEditorGroupsThroughThePage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "main.txt")
	if err := os.WriteFile(path, []byte("text\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.app.reduceChrome(core.SetChromeOpen(itemTerminal, true))
		h.settle()
	}
	h.app.openFile(h.app.project, path)
	h.app.newTerminal(h.app.project, "")
	h.settle()
	h.frames()
	set := &h.app.project.terms
	if len(set.list) != 2 || set.layout == nil {
		t.Fatalf("terminals %d, layout %v, want two terminals and an editor group", len(set.list), set.layout)
	}
	strip, group := h.app.term.groups[0].strip, h.app.term.groups[0].id

	// Dropped on the editor's strip, the tabs join the group.
	for _, term := range set.list {
		tab := h.tabHit(h.app.terminalTitle(term))
		h.drag(center(tab), gfx.Point{X: strip.X + strip.Width - 4, Y: strip.Y + strip.Height/2})
		h.settle()
		h.frames()
		if g := set.bench.GroupOf(terminalMember(term.id)); g == nil || g.ID != group {
			t.Fatalf("terminal %d is in %+v, want group %s", term.id, g, group)
		}
	}
	if h.app.dnd.tab.Dragging() || h.app.term.drag.active {
		t.Fatal("the release did not end the drag")
	}

	// Dragged to the right edge of the group's body, a tab splits the group.
	tab := h.tabHit(h.app.terminalTitle(set.list[1]))
	body := h.app.term.groups[0].body
	h.drag(center(tab), gfx.Point{X: body.Right() - 10, Y: body.Y + body.Height/2})
	h.settle()
	if set.layout.leaf() || !set.layout.row {
		t.Fatalf("the layout is %+v, want the group split side by side", set.layout)
	}
	if got := len(h.app.term.groups); got != 2 {
		t.Fatalf("%d editor groups painted, want 2", got)
	}
}

// A file's tab is dragged like a terminal's: to the bottom edge of its group it splits the
// group one over the other, and the file stays open and selected in the new group.
func TestFileTabDragSplitsTheEditorThroughThePage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	for _, name := range []string{"one.txt", "two.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "one.txt"))
	h.app.openFile(p, filepath.Join(root, "two.txt"))
	h.settle()
	h.frames()
	set := &p.terms
	if set.layout == nil || !set.layout.leaf() {
		t.Fatalf("layout %+v, want one editor group", set.layout)
	}
	doc := p.docs.byPath(filepath.Join(root, "two.txt"))
	if doc == nil {
		t.Fatal("two.txt is not open")
	}
	member := documentMember(doc.id)
	before := set.bench.GroupOf(member).ID

	tab := h.tabHit(doc.name)
	body := h.app.term.groups[0].body
	h.drag(center(tab), gfx.Point{X: body.X + body.Width/2, Y: body.Bottom() - 10})
	h.settle()
	h.frames()
	if set.layout.leaf() || set.layout.row {
		t.Fatalf("the layout is %+v, want the group split one over the other", set.layout)
	}
	g := set.bench.GroupOf(member)
	if g == nil || g.ID == before || g.Selected != member {
		t.Fatalf("the file is in %+v, want it selected in a new group", g)
	}
	if h.app.dnd.tab.Dragging() || h.app.term.drag.active {
		t.Fatal("the release did not end the drag")
	}
}
