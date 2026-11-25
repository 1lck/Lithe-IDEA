package workbench

import (
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// resultTreeFocus drives Viva's real tree and each panel's selection adapter without
// background queries: the test controls when a result arrives relative to a paint.
type resultTreeFocus struct {
	view        *ui.TreeState
	selected    *string
	selectedRow *int
	focus       *gfx.ID
	reveal      *bool
	sync        func(*gfx.Canvas)
	setRows     func(...string)
	row         func(int) string
	count       func() int
	driver      *app.Driver
	invalidator *app.Invalidator
}

func newResultTreeFocus(t *testing.T, panel string) *resultTreeFocus {
	t.Helper()
	a := new(App)
	f := &resultTreeFocus{invalidator: new(app.Invalidator)}
	switch panel {
	case "references":
		s := &a.editor.refs
		f.view, f.selected, f.selectedRow, f.focus, f.reveal = &s.view, &s.selected, &s.selectedRow, &s.focus, &s.reveal
		f.sync = a.syncReferenceSelection
		f.setRows = func(keys ...string) {
			s.rows = nil
			for _, key := range keys {
				s.rows = append(s.rows, core.ReferenceRow{Key: key})
			}
		}
		f.row = func(i int) string { return s.rows[i].Key }
		f.count = func() int { return len(s.rows) }
	case "problems":
		v := &a.problems
		f.view, f.selected, f.selectedRow, f.focus, f.reveal = &v.view, &v.selected, &v.selectedRow, &v.focus, &v.reveal
		f.sync = a.syncProblemsSelection
		f.setRows = func(keys ...string) {
			v.result.Rows = nil
			for _, key := range keys {
				v.result.Rows = append(v.result.Rows, core.ProblemsRow{Key: key})
			}
		}
		f.row = func(i int) string { return v.result.Rows[i].Key }
		f.count = func() int { return len(v.result.Rows) }
	default:
		t.Fatalf("unknown result tree %q", panel)
	}
	f.setRows("first", "original")
	*f.selected, *f.selectedRow = "original", 1
	f.view.Node = func(i int) ui.TreeNode { return ui.TreeNode{Selected: i == *f.selectedRow} }
	f.view.RowHeight = 24
	theme := ui.LightTheme()
	page := ui.NewPage(ui.PageConfig{
		Theme: &theme, Invalidator: f.invalidator,
		View: func(c ui.C) {
			f.sync(c.Canvas())
			ui.Tree(c, f.view, f.count(), f.row, func(i int) { ui.Text(c, f.row(i)) }).Scrollbars().Fill()
		},
	})
	var err error
	f.driver, err = app.NewDriver(ui.Configure(page, app.Config{Width: 300, Height: 120, Invalidator: f.invalidator}), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.driver.Close)
	f.paint(t)
	return f
}

func (f *resultTreeFocus) paint(t *testing.T) {
	t.Helper()
	f.invalidator.Invalidate()
	if err := f.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
}

func (f *resultTreeFocus) wantSelection(t *testing.T, key string, row int) {
	t.Helper()
	if *f.selected != key || *f.selectedRow != row || f.view.Selected() != row {
		t.Fatalf("selection = %q at %d (tree %d), want %q at %d", *f.selected, *f.selectedRow, f.view.Selected(), key, row)
	}
}

func TestResultTreesKeepSelectionWhenFocusClearsBeforeNewRowsPaint(t *testing.T) {
	for _, panel := range []string{"references", "problems"} {
		t.Run(panel, func(t *testing.T) {
			f := newResultTreeFocus(t, panel)
			*f.focus = f.view.RowID(0)
			if f.focus.IsZero() {
				t.Fatal("the painted row has no identity")
			}
			// A result arrives before the frame that observes cleared focus. The new
			// row has no Viva identity yet; it must not match the cleared focus.
			f.setRows("first", "original", "new")
			if !f.view.RowID(2).IsZero() {
				t.Fatal("the new row already has an identity")
			}
			canvas := new(gfx.Canvas)
			f.sync(canvas)
			f.wantSelection(t, "original", 1)
			if !f.focus.IsZero() {
				t.Fatal("cleared focus was not recorded")
			}

			// With focus unchanged at zero, a toolbar reveal must also preserve the
			// selection and must not give the keyboard to an unpainted row.
			*f.reveal = true
			f.sync(canvas)
			f.wantSelection(t, "original", 1)
			if *f.reveal || !canvas.FocusRequest().IsZero() {
				t.Fatal("reveal did not finish without taking focus")
			}

			// Returning to the same identity used before focus cleared is a new
			// focus change and must select it, even though another row was kept.
			canvas.SetInteraction(gfx.ID{}, gfx.ID{}, f.view.RowID(0), true)
			f.sync(canvas)
			f.wantSelection(t, "first", 0)
		})
	}
}

func TestResultTreesSelectionFollowsArrowKeys(t *testing.T) {
	for _, panel := range []string{"references", "problems"} {
		t.Run(panel, func(t *testing.T) {
			f := newResultTreeFocus(t, panel)
			// Tab enters the currently selected row; arrows then use Viva's own
			// navigation and the panel observes the focused row on the next frame.
			for _, key := range []gfx.Key{gfx.KeyTab, gfx.KeyUp} {
				if err := f.driver.Key(key, 0); err != nil {
					t.Fatal(err)
				}
				f.paint(t)
			}
			f.wantSelection(t, "first", 0)
			if err := f.driver.Key(gfx.KeyDown, 0); err != nil {
				t.Fatal(err)
			}
			f.paint(t)
			f.wantSelection(t, "original", 1)
		})
	}
}

func TestResultTreesRevealKeepsTheSelectionMadeOutsideTheTree(t *testing.T) {
	for _, panel := range []string{"references", "problems"} {
		t.Run(panel, func(t *testing.T) {
			f := newResultTreeFocus(t, panel)
			canvas := new(gfx.Canvas)
			canvas.SetInteraction(gfx.ID{}, gfx.ID{}, f.view.RowID(0), true)
			f.sync(canvas)
			f.wantSelection(t, "first", 0)

			// A toolbar action changed the selection while the first row still has
			// focus. Revealing it transfers focus without reverting the selection.
			*f.selected, *f.selectedRow, *f.reveal = "original", 1, true
			f.sync(canvas)
			f.wantSelection(t, "original", 1)
			if *f.reveal || canvas.FocusRequest() != f.view.RowID(1) {
				t.Fatal("reveal did not hand focus to the selected row")
			}

			// An unrelated control's focus cannot change the selection, including
			// after the result becomes empty while a stale focus identity remains.
			canvas = new(gfx.Canvas)
			canvas.SetInteraction(gfx.ID{}, gfx.ID{}, gfx.Item(99), true)
			*f.reveal = true
			f.sync(canvas)
			f.wantSelection(t, "original", 1)
			if !canvas.FocusRequest().IsZero() {
				t.Fatal("reveal took focus from another control")
			}
			f.setRows()
			f.sync(canvas)
			if f.view.Selected() != -1 {
				t.Fatal("the empty tree still selects a row")
			}
		})
	}
}
