package workbench

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
)

// openTabs opens a project of n files whose names are long enough that a few of their tabs
// fill an editor group's strip, opens them all in that order and paints the frames the strip
// asks for once it has measured itself. It returns the files' documents in order and the
// group they are in.
func (h *harness) openTabs(t *testing.T, n int) ([]*document, string) {
	t.Helper()
	root := t.TempDir()
	paths := make([]string, n)
	for i := range paths {
		paths[i] = filepath.Join(root, fmt.Sprintf("tab-%02d-%s.txt", i, strings.Repeat("long", 6)))
		if err := os.WriteFile(paths[i], []byte("text\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	docs := make([]*document, n)
	for i, path := range paths {
		h.app.openFile(h.app.project, path)
		h.settle()
		if docs[i] = h.app.project.docs.byPath(path); docs[i] == nil {
			t.Fatalf("%s did not open", path)
		}
	}
	h.frames()
	if len(h.app.term.groups) != 1 {
		t.Fatalf("the files are in %d editor groups, want 1", len(h.app.term.groups))
	}
	return docs, h.app.term.groups[0].id
}

// frames paints the frames the strips of tabs ask for after they measure themselves. The
// driver's time is virtual, so this is a fixed number of frames, not a wait; a strip settles
// within two of them.
func (h *harness) frames() {
	h.t.Helper()
	if err := h.driver.Advance(100 * time.Millisecond); err != nil {
		h.t.Fatal(err)
	}
}

// press clicks at the middle of r and paints what the click did.
func (h *harness) press(r gfx.Rect) {
	h.t.Helper()
	at := center(r)
	if err := h.driver.Click(at.X, at.Y); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
	h.frames()
}

// selectedMember is the member group selects.
func (h *harness) selectedMember(group string) string {
	h.t.Helper()
	g := h.app.project.terms.bench.Group(group)
	if g == nil {
		h.t.Fatalf("group %s is gone", group)
	}
	return g.Selected
}

// inside says r lies within view, give or take the layout's rounding.
func inside(r, view gfx.Rect) bool {
	return r.X >= view.X-tabHideSlack && r.Right() <= view.Right()+tabHideSlack
}

// A strip whose tabs do not fit scrolls sideways: the selected tab is scrolled into view, a
// thin bar along the top shows where the row is, the wheel scrolls it, and the button at its
// end lists the tabs it does not show. Picking one there selects it and scrolls it into
// view; its close button closes it and keeps the list open; Escape and a click elsewhere
// close the list.
func TestEditorTabsScrollAndListTheHiddenOnes(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	docs, group := h.openTabs(t, 12)
	s := h.app.term.strips[group]
	if s == nil || !s.scroll.Overflows() {
		t.Fatalf("twelve long tabs fit their strip: %+v", s)
	}
	view := s.scroll.Area
	first, last := docs[0], docs[len(docs)-1]
	if tab := h.hit(docTabs.At(last.id)); !inside(tab, view) {
		t.Fatalf("the selected tab %+v is not scrolled into the strip %+v", tab, view)
	}
	if !slices.Contains(s.hidden, documentMember(first.id)) || slices.Contains(s.hidden, documentMember(last.id)) {
		t.Fatalf("hidden = %v, want the first tab and not the selected last one", s.hidden)
	}
	if _, length, ok := s.scroll.Thumb(); !ok || length >= view.Width {
		t.Fatalf("the strip shows no scrollbar: length %v of %v", length, view.Width)
	}

	// A plain turn of the wheel over the strip scrolls it sideways, back to the start.
	if err := h.driver.Scroll(gfx.ScrollEvent{X: view.X + 20, Y: view.Y + view.Height/2, DeltaY: -100000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.frames()
	if s.scroll.Offset != 0 {
		t.Fatalf("the wheel left the strip at %v, want 0", s.scroll.Offset)
	}
	if tab := h.hit(docTabs.At(first.id)); !inside(tab, view) {
		t.Fatalf("scrolled to the start, the first tab %+v is not in the strip %+v", tab, view)
	}
	if !slices.Contains(s.hidden, documentMember(last.id)) {
		t.Fatalf("scrolled to the start, hidden = %v lacks the last tab", s.hidden)
	}
	if h.selectedMember(group) != documentMember(last.id) {
		t.Fatal("scrolling the strip changed the selection")
	}

	// The list of hidden tabs selects the one picked and scrolls it into view.
	more := h.hit(tabMore.At(0))
	if more.X < view.Right()-tabHideSlack {
		t.Fatalf("the button %+v is not after the tabs, which end at %v", more, view.Right())
	}
	h.press(more)
	if !s.menu {
		t.Fatal("the button did not open the list of hidden tabs")
	}
	picked := docs[len(docs)-2]
	h.press(h.topHit(tabHidden.At(shownTab{doc: picked}.key())))
	if s.menu {
		t.Fatal("picking a tab left the list open")
	}
	if h.selectedMember(group) != documentMember(picked.id) {
		t.Fatalf("picking %s selected %s", documentMember(picked.id), h.selectedMember(group))
	}
	if tab := h.hit(docTabs.At(picked.id)); !inside(tab, view) {
		t.Fatalf("the picked tab %+v is not scrolled into the strip %+v", tab, view)
	}

	// Its close button closes a hidden tab and leaves the list open on the rest.
	h.press(h.hit(tabMore.At(0)))
	if !slices.Contains(s.hidden, documentMember(first.id)) {
		t.Fatalf("hidden = %v lacks the first tab", s.hidden)
	}
	h.press(h.topHit(tabHiddenClose.At(shownTab{doc: first}.key())))
	if h.app.project.docs.find(first.id) != nil {
		t.Fatal("the close button of a hidden tab did not close its file")
	}
	if !s.menu || slices.Contains(s.hidden, documentMember(first.id)) {
		t.Fatalf("after closing a hidden tab the list is open %v with %v", s.menu, s.hidden)
	}
	if h.selectedMember(group) != documentMember(picked.id) {
		t.Fatal("closing a hidden tab changed the selection")
	}

	// Escape closes the list, and so does a click anywhere else, which does nothing more.
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if s.menu {
		t.Fatal("Escape left the list of hidden tabs open")
	}
	h.press(h.hit(tabMore.At(0)))
	if !s.menu {
		t.Fatal("the button did not open the list again")
	}
	body := h.app.term.groups[0].body.Rect()
	h.press(gfx.Rect{X: body.X + body.Width/2, Y: body.Y + body.Height/2, Width: 1, Height: 1})
	if s.menu {
		t.Fatal("a click outside left the list of hidden tabs open")
	}
	if h.selectedMember(group) != documentMember(picked.id) {
		t.Fatal("the click that closed the list changed the selection")
	}
}

// The editor's tab setting squeezes the tabs of one row, or wraps them onto as many rows as
// they need with the strip's buttons at the end of the first, and back.
func TestEditorTabsSqueezeOrWrapByTheSetting(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	docs, group := h.openTabs(t, 12)
	s := h.app.term.strips[group]
	last := docs[len(docs)-1]
	wide := h.hit(docTabs.At(last.id)).Width
	set := func(apply func(*App)) {
		t.Helper()
		h.app.post(apply)
		h.settle()
		h.frames()
	}

	set(func(a *App) { a.setTabOverflow(settingswindow.TabOverflowSqueeze) })
	if h.app.settings.EditorTabOverflow != settingswindow.TabOverflowSqueeze {
		t.Fatalf("the setting stored %q", h.app.settings.EditorTabOverflow)
	}
	squeezed := h.hit(docTabs.At(last.id))
	if squeezed.Width >= wide || squeezed.Width < terminalChipMinWidth-tabHideSlack {
		t.Fatalf("a squeezed tab is %v wide, want less than %v and at least %v", squeezed.Width, wide, terminalChipMinWidth)
	}
	if !inside(squeezed, s.scroll.Area) {
		t.Fatalf("the selected squeezed tab %+v is not in the strip %+v", squeezed, s.scroll.Area)
	}

	set(func(a *App) { a.setTabRows(settingswindow.TabRowsMultiple) })
	strip := h.app.term.groups[0].strip.Rect()
	rows := int(strip.Height / panelHeaderHeight)
	if rows < 2 || strip.Height != float32(rows*panelHeaderHeight) {
		t.Fatalf("a wrapped strip is %v high, want two or more rows of %v", strip.Height, panelHeaderHeight)
	}
	if len(s.hidden) != 0 || s.menu {
		t.Fatalf("a wrapped strip hides %v", s.hidden)
	}
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == tabMore.At(0) {
			t.Fatal("a wrapped strip shows the button that lists hidden tabs")
		}
	}
	top := float32(-1)
	for i, d := range docs {
		tab := h.hit(docTabs.At(d.id))
		if tab.X < strip.X || tab.Right() > strip.Right()+tabHideSlack || tab.Y < strip.Y || tab.Bottom() > strip.Bottom() {
			t.Fatalf("tab %d at %+v is outside the strip %+v", i, tab, strip)
		}
		if tab.Y < top {
			t.Fatalf("tab %d at %+v is on a row above the tab before it", i, tab)
		}
		top = tab.Y
	}
	if top <= strip.Y+panelHeaderHeight/2 {
		t.Fatal("every tab is on the first row")
	}
	wrap := h.hit(docWrap.At(last.id))
	if wrap.Y >= strip.Y+panelHeaderHeight {
		t.Fatalf("the soft wrap switch %+v is not on the first row of %+v", wrap, strip)
	}

	set(func(a *App) { a.setTabRows("") })
	set(func(a *App) { a.setTabOverflow("") })
	if h.app.settings.EditorTabRows != "" || h.app.settings.EditorTabOverflow != "" {
		t.Fatalf("the defaults stored %q %q", h.app.settings.EditorTabRows, h.app.settings.EditorTabOverflow)
	}
	if strip := h.app.term.groups[0].strip.Rect(); strip.Height != panelHeaderHeight {
		t.Fatalf("one row again, the strip is %v high", strip.Height)
	}
	if tab := h.hit(docTabs.At(last.id)); tab.Width != wide || !inside(tab, s.scroll.Area) {
		t.Fatalf("one scrolling row again, the selected tab is %+v, want %v wide in %+v", tab, wide, s.scroll.Area)
	}
}

func TestWrapTabs(t *testing.T) {
	cases := []struct {
		name   string
		widths []float32
		avail  float32
		want   []int
	}{
		{"no tabs", nil, 100, []int{0}},
		{"all fit", []float32{30, 30, 30}, 100, []int{0}},
		{"exactly fit", []float32{48, 48}, 100, []int{0}},
		{"one past", []float32{48, 49}, 100, []int{0, 1}},
		{"several rows", []float32{60, 30, 60, 60, 10}, 100, []int{0, 2, 3}},
		{"a tab wider than a row", []float32{150, 20, 150}, 100, []int{0, 1, 2}},
	}
	for _, c := range cases {
		if got := wrapTabs(nil, c.widths, c.avail, 4); !slices.Equal(got, c.want) {
			t.Errorf("%s: wrapTabs = %v, want %v", c.name, got, c.want)
		}
	}
}
