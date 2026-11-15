package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// A file of the project replace preview opens from its context menu, as the earlier client's
// replace preview rows did; the preview is modal, so it closes first.
func TestReplacePreviewFileMenuOpensTheFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "src", "main.txt")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) {
		p.replace = projectReplace{
			open:     true,
			files:    []core.WorkspaceReplaceFile{{Path: "src/main.txt", Matches: []core.WorkspaceReplaceMatch{{Line: 2, Before: "two", After: "2", OccurrenceCount: 1}}}},
			include:  []bool{true},
			expanded: map[string]bool{},
		}
	})
	h.settle()
	var row gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == h.shared("desktop.search.replaceFile") && hit.Value == "src/main.txt" {
			row = hit.Bounds
		}
	}
	if row.Width == 0 {
		t.Fatal("the replace preview has no row for src/main.txt")
	}
	// The row's empty middle, clear of its checkbox and its buttons.
	h.rightClickAt(gfx.Rect{X: row.X + row.Width/2, Y: row.Y, Width: 1, Height: row.Height})
	h.click(center(h.popupHit(h.shared("desktop.files.open"))))
	awaitStateWithin(t, h, 10*time.Second, "the replaced file", func() bool { return p.docs.byPath(path) != nil })
	if p.replace.open {
		t.Fatal("opening a file left the modal replace preview open")
	}
}
