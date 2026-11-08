package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The switch at the end of the strip of a group that shows a file turns soft wrapping on and
// off, says which it is to assistive technology, and sits to the right of the file's tab.
func TestSoftWrapSwitchWrapsTheOpenFile(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	path := filepath.Join(project, "long.txt")
	if err := os.WriteFile(path, []byte(strings.Repeat("word ", 400)+"\nend\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.open(project)
	h.app.openFile(h.app.project, path)
	h.settle()

	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the file did not open")
	}
	id := docWrap.At(d.id)
	switchHit := func() ui.Hit {
		t.Helper()
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.ID == id {
				return hit
			}
		}
		t.Fatal("the soft wrap switch is not shown")
		return ui.Hit{}
	}
	hit := switchHit()
	if hit.Label != h.app.text.Editor.SoftWrap || hit.Role != ui.RoleSwitch || hit.Checked {
		t.Fatalf("switch = %q role %v checked %v, want %q, an unchecked switch", hit.Label, hit.Role, hit.Checked, h.app.text.Editor.SoftWrap)
	}
	if tab := h.hit(docTabs.At(d.id)); hit.Bounds.X < tab.X+tab.Width {
		t.Fatalf("the switch at x %v is not right of the file's tab, which ends at %v", hit.Bounds.X, tab.X+tab.Width)
	}

	click := func() {
		t.Helper()
		at := center(switchHit().Bounds)
		if err := h.driver.Click(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	click()
	if !h.app.softWrap || !d.view.Wrap() {
		t.Fatalf("after a click softWrap = %v and the view wraps = %v, want both on", h.app.softWrap, d.view.Wrap())
	}
	if !switchHit().Checked {
		t.Fatal("the switch does not say wrapping is on")
	}
	click()
	if h.app.softWrap || d.view.Wrap() {
		t.Fatalf("after a second click softWrap = %v and the view wraps = %v, want both off", h.app.softWrap, d.view.Wrap())
	}
}
