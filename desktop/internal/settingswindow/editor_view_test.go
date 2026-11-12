package settingswindow

import (
	"slices"
	"testing"

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
	d := openWindow(t, w)
	settings := w.text.Settings

	if hit := d.hit(settings.TabsScroll); hit.Role != gfx.RoleRadio || !hit.Checked {
		t.Fatalf("an unknown stored overflow does not show scrolling: %+v", hit)
	}
	d.click(settings.TabsSqueeze)
	if !slices.Equal(overflow, []string{TabOverflowSqueeze}) || len(rows) != 0 {
		t.Fatalf("squeeze: rows=%v overflow=%v", rows, overflow)
	}
	d.click(settings.TabsMultipleRows)
	if !slices.Equal(rows, []string{TabRowsMultiple}) {
		t.Fatalf("multiple rows: rows=%v", rows)
	}
	if hit := d.hit(settings.TabsScroll); !hit.Disabled {
		t.Fatalf("one-row choice is not disabled under several rows: %+v", hit)
	}
	d.click(settings.TabsScroll)
	if !slices.Equal(overflow, []string{TabOverflowSqueeze}) {
		t.Fatalf("a disabled choice applied: overflow=%v", overflow)
	}
	d.click(settings.TabsOneRow)
	if !slices.Equal(rows, []string{TabRowsMultiple, ""}) {
		t.Fatalf("one row: rows=%v", rows)
	}
	if hit := d.hit(settings.TabsSqueeze); hit.Disabled || !hit.Checked {
		t.Fatalf("one row lost the squeeze choice: %+v", hit)
	}
	d.click("Restore Defaults")
	if !slices.Equal(rows, []string{TabRowsMultiple, "", ""}) || !slices.Equal(overflow, []string{TabOverflowSqueeze, ""}) {
		t.Fatalf("restore: rows=%v overflow=%v", rows, overflow)
	}
}

// TestEditorSemanticHighlightSwitchAppliesAndRestores walks the Editor page's semantic
// switch: a change reaches the settings owner at once, and Restore Defaults turns the colors
// back on.
func TestEditorSemanticHighlightSwitchAppliesAndRestores(t *testing.T) {
	var disabled []bool
	w := newWindow(NewController(Options{
		SetDisableSemanticHighlight: func(value bool) { disabled = append(disabled, value) },
	}), Values{})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	settings := w.text.Settings

	if hit := d.hit(settings.SemanticHighlight); hit.Role != gfx.RoleSwitch || !hit.Checked {
		t.Fatalf("semantic highlighting starts on: %+v", hit)
	}
	d.click(settings.SemanticHighlight)
	if !slices.Equal(disabled, []bool{true}) {
		t.Fatalf("turning the colors off = %v", disabled)
	}
	if hit := d.hit(settings.SemanticHighlight); hit.Checked {
		t.Fatalf("the switch kept its on state: %+v", hit)
	}
	d.click(settings.SemanticHighlight)
	if !slices.Equal(disabled, []bool{true, false}) {
		t.Fatalf("turning the colors back on = %v", disabled)
	}
	d.click(settings.SemanticHighlight)
	d.click("Restore Defaults")
	if len(disabled) != 4 || disabled[len(disabled)-1] {
		t.Fatalf("restore = %v, want a final enabled value", disabled)
	}
}
