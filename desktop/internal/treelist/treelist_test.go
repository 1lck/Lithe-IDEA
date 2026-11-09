package treelist

import (
	"testing"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	ids  = gfx.Tree{}
	page = ids.Feature("treelist-test")
	list = List{
		Scroll: ids.ID(page, "scroll"),
		Rows:   ids.Sub(page, ids.Name("rows")),
		Arrows: ids.Sub(page, ids.Name("arrows")),
	}
)

// sample is a tree of an open folder with a closed folder and a file in it, and a file at the
// top: the keys are not the indices, as they are not in a real tree.
var sample = []Row{
	{Key: 10, Label: "src", Depth: 0, Branch: true, Expanded: true},
	{Key: 11, Label: "a", Depth: 1, Branch: true},
	{Key: 12, Label: "b.go", Depth: 1},
	{Key: 13, Label: "top.txt", Depth: 0},
}

// viewOf is a view whose list shows viewport pixels of rows, scrolled offset into them.
func viewOf(viewport, offset float32) *ui.View {
	view := new(ui.View)
	scroll := view.ScrollState(list.Scroll)
	scroll.Viewport, scroll.Offset = viewport, offset
	return view
}

func TestGeometry(t *testing.T) {
	if got, want := Width(0, 100), float32(2*Gutter+Disclosure+Gap+100+Trailing); got != want {
		t.Fatalf("Width(0, 100) = %v, want %v", got, want)
	}
	if got, want := Width(2, 100)-Width(0, 100), float32(2*Indent); got != want {
		t.Fatalf("two levels in widen a row by %v, want %v", got, want)
	}
	if RowTop(0) != PadY || RowTop(3) != PadY+3*RowHeight {
		t.Fatalf("RowTop(0) = %v, RowTop(3) = %v", RowTop(0), RowTop(3))
	}
}

func TestIndex(t *testing.T) {
	if Index(sample, 12) != 2 || Index(sample, 10) != 0 || Index(sample, 99) != -1 || Index(nil, 0) != -1 {
		t.Fatal("Index did not find rows by their key")
	}
}

func TestRevealScrollsAsLittleAsNeeded(t *testing.T) {
	view := viewOf(100, 0)
	list.Reveal(view, 1)
	if offset := view.ScrollState(list.Scroll).Offset; offset != 0 {
		t.Fatalf("revealing a row in view scrolled to %v", offset)
	}
	list.Reveal(view, 10)
	if got, want := view.ScrollState(list.Scroll).Offset, RowTop(10)+RowHeight-100; got != want {
		t.Fatalf("revealing a row below the view scrolled to %v, want its bottom at the view's: %v", got, want)
	}
	list.Reveal(view, 0)
	if got := view.ScrollState(list.Scroll).Offset; got != RowTop(0) {
		t.Fatalf("revealing a row above the view scrolled to %v, want its top: %v", got, RowTop(0))
	}
}

func TestCenterLeavesARowInViewAndCentersOneOutOfIt(t *testing.T) {
	view := viewOf(100, 0)
	list.Center(view, 1)
	if offset := view.ScrollState(list.Scroll).Offset; offset != 0 {
		t.Fatalf("centering a row in view scrolled to %v", offset)
	}
	list.Center(view, 20)
	if got, want := view.ScrollState(list.Scroll).Offset, RowTop(20)-(100-RowHeight)/2; got != want {
		t.Fatalf("centering a row out of view scrolled to %v, want %v", got, want)
	}
}

func TestTopRowRoundTrips(t *testing.T) {
	view := viewOf(100, RowTop(3)+5)
	i, offset := list.TopRow(view, len(sample))
	if i != 3 || offset != 5 {
		t.Fatalf("TopRow = %d, %v, want 3, 5", i, offset)
	}
	view.ScrollState(list.Scroll).ScrollTo(0)
	list.ScrollToRow(view, i, offset)
	if got := view.ScrollState(list.Scroll).Offset; got != RowTop(3)+5 {
		t.Fatalf("ScrollToRow went to %v", got)
	}
	if i, _ := list.TopRow(view, 2); i != 1 {
		t.Fatalf("TopRow past the last row is %d, want the last row", i)
	}
	if i, _ := list.TopRow(view, 0); i != -1 {
		t.Fatalf("TopRow of no rows is %d", i)
	}
}

func TestKeyMovesAndOpensAsADesktopTree(t *testing.T) {
	press := func(key gfx.Key, target gfx.ID) gfx.KeyEvent { return gfx.KeyEvent{Key: key, Target: target} }
	cases := []struct {
		name    string
		event   gfx.KeyEvent
		current int
		action  Action
		row     int
	}{
		{"down", press(gfx.KeyDown, list.Rows.At(10)), 0, Select, 1},
		{"right opens a closed branch", press(gfx.KeyRight, list.Rows.At(11)), 1, Expand, 1},
		{"left on a closed branch goes to its parent", press(gfx.KeyLeft, list.Rows.At(11)), 1, Select, 0},
		{"left closes an open branch", press(gfx.KeyLeft, list.Rows.At(10)), 0, Collapse, 0},
		{"enter activates", press(gfx.KeyEnter, list.Rows.At(12)), 2, Activate, 2},
		{"the keyboard's row stands for a hidden selection", press(gfx.KeyUp, list.Arrows.At(12)), -1, Select, 1},
		{"up on the first row does nothing", press(gfx.KeyUp, list.Rows.At(10)), 0, None, 0},
	}
	for _, c := range cases {
		action, row, handled := list.Key(c.event, viewOf(100, 0), sample, c.current)
		if !handled || action != c.action || row != c.row {
			t.Errorf("%s: Key = %v, %d, %v, want %v, %d", c.name, action, row, handled, c.action, c.row)
		}
	}

	ignored := []struct {
		name  string
		event gfx.KeyEvent
	}{
		{"a release", gfx.KeyEvent{Key: gfx.KeyDown, Target: list.Rows.At(10), Release: true}},
		{"a chord", gfx.KeyEvent{Key: gfx.KeyDown, Target: list.Rows.At(10), Modifiers: gfx.ModifierMeta}},
		{"a key outside the list", press(gfx.KeyDown, ids.ID(page, "elsewhere"))},
		{"a key the tree does not use", press(gfx.KeyTab, list.Rows.At(10))},
		{"a row that is not shown", press(gfx.KeyDown, list.Rows.At(99))},
	}
	for _, c := range ignored {
		if _, _, handled := list.Key(c.event, viewOf(100, 0), sample, -1); handled {
			t.Errorf("%s was handled", c.name)
		}
	}
}

func TestKeyScrollsTheRowItSelectsIntoView(t *testing.T) {
	rows := make([]Row, 20)
	for i := range rows {
		rows[i] = Row{Key: i, Depth: 0}
	}
	view := viewOf(3*RowHeight, 0)
	if action, row, _ := list.Key(gfx.KeyEvent{Key: gfx.KeyEnd, Target: list.Rows.At(0)}, view, rows, 0); action != Select || row != 19 {
		t.Fatalf("End = %v, %d", action, row)
	}
	if got, want := view.ScrollState(list.Scroll).Offset, RowTop(19)+RowHeight-3*RowHeight; got != want {
		t.Fatalf("End scrolled to %v, want %v", got, want)
	}
}

func TestDoubleClicked(t *testing.T) {
	second := gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 2, Target: list.Rows.At(12)}
	if key, ok := list.DoubleClicked(second); !ok || key != 12 {
		t.Fatalf("a double click on row 12 read as %d, %v", key, ok)
	}
	for name, event := range map[string]gfx.PointerEvent{
		"a single click": {Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 1, Target: list.Rows.At(12)},
		"a release":      {Kind: gfx.PointerUp, Button: gfx.PointerButtonPrimary, ClickCount: 2, Target: list.Rows.At(12)},
		"another button": {Kind: gfx.PointerDown, Button: gfx.PointerButtonSecondary, ClickCount: 2, Target: list.Rows.At(12)},
		"a chord":        {Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 2, Modifiers: gfx.ModifierShift, Target: list.Rows.At(12)},
		"an arrow":       {Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 2, Target: list.Arrows.At(12)},
	} {
		if _, ok := list.DoubleClicked(event); ok {
			t.Errorf("%s read as a double click", name)
		}
	}
}
