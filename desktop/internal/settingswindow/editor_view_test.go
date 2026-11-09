package settingswindow

import (
	"slices"
	"testing"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// TestEditorTabPlacementAppliesAndRestores walks the choices of the editor page's tab card:
// each one reaches its setter at once, the two choices for one row are inert while several
// rows are chosen, and Restore Defaults clears both settings.
func TestEditorTabPlacementAppliesAndRestores(t *testing.T) {
	var rows, overflow []string
	w := newWindow(NewController(Options{
		SetTabRows:     func(value string) { rows = append(rows, value) },
		SetTabOverflow: func(value string) { overflow = append(overflow, value) },
	}), Values{EditorTabOverflow: "unknown"})
	w.sess.page = pageEditor
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { w.market.close(); driver.Close() })
	find := func(id gfx.ID) gfx.Hit {
		t.Helper()
		for _, hit := range driver.Snapshot().Hits {
			if hit.ID == id {
				return hit
			}
		}
		t.Fatalf("control %v was not found", id)
		return gfx.Hit{}
	}
	click := func(id gfx.ID) {
		t.Helper()
		hit := find(id)
		if err := driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
			t.Fatal(err)
		}
	}

	if hit := find(tabOverflowScope.At(0)); hit.Role != gfx.RoleRadio || !hit.Checked {
		t.Fatalf("an unknown stored overflow does not show scrolling: %+v", hit)
	}
	click(tabOverflowScope.At(1))
	if !slices.Equal(overflow, []string{TabOverflowSqueeze}) || len(rows) != 0 {
		t.Fatalf("squeeze: rows=%v overflow=%v", rows, overflow)
	}
	click(tabRowsScope.At(1))
	if !slices.Equal(rows, []string{TabRowsMultiple}) {
		t.Fatalf("multiple rows: rows=%v", rows)
	}
	if hit := find(tabOverflowScope.At(0)); !hit.Disabled {
		t.Fatalf("one-row choice is not disabled under several rows: %+v", hit)
	}
	click(tabOverflowScope.At(0))
	if !slices.Equal(overflow, []string{TabOverflowSqueeze}) {
		t.Fatalf("a disabled choice applied: overflow=%v", overflow)
	}
	click(tabRowsScope.At(0))
	if !slices.Equal(rows, []string{TabRowsMultiple, ""}) {
		t.Fatalf("one row: rows=%v", rows)
	}
	if hit := find(tabOverflowScope.At(1)); hit.Disabled || !hit.Checked {
		t.Fatalf("one row lost the squeeze choice: %+v", hit)
	}
	click(restoreID)
	if !slices.Equal(rows, []string{TabRowsMultiple, "", ""}) || !slices.Equal(overflow, []string{TabOverflowSqueeze, ""}) {
		t.Fatalf("restore: rows=%v overflow=%v", rows, overflow)
	}
}
