package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestNavigationHistoryStepsBackAndForward(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	a, b := filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")
	for path, text := range map[string]string{a: "one\ntwo\nthree", b: "x\ny\nz"} {
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, a)
	h.settle()
	docA := p.docs.byPath(a)
	docA.view.GoToNavigation(1, 2, false)

	// A jump to b records where the caret was in a.
	h.app.openFileAtPosition(p, b, 2, 0)
	h.settle()
	selected := func() (string, int, int) {
		d := p.selectedDocument(p.docs.group)
		line, column := d.view.CaretUTF16()
		return d.path, line, column
	}
	if path, line, column := selected(); path != b || line != 2 || column != 0 {
		t.Fatalf("after jump: %s %d:%d", path, line, column)
	}
	h.app.stepNavigation(p, false)
	h.settle()
	if path, line, column := selected(); path != a || line != 1 || column != 2 {
		t.Fatalf("after back: %s %d:%d", path, line, column)
	}
	h.app.stepNavigation(p, true)
	h.settle()
	if path, line, column := selected(); path != b || line != 2 || column != 0 {
		t.Fatalf("after forward: %s %d:%d", path, line, column)
	}
	// With nothing further forward the caret stays.
	h.app.stepNavigation(p, true)
	h.settle()
	if path, _, _ := selected(); path != b {
		t.Fatalf("forward at the end moved to %s", path)
	}
}

func TestNavigationHistoryKeepsEntryOfMissingFile(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	a, b := filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")
	for _, path := range []string{a, b} {
		if err := os.WriteFile(path, []byte("1\n2"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, a)
	h.settle()
	h.app.openFileAtPosition(p, b, 1, 0)
	h.settle()
	if err := os.Remove(a); err != nil {
		t.Fatal(err)
	}
	before := len(h.app.editor.nav.history.Back)
	h.app.stepNavigation(p, false)
	if got := len(h.app.editor.nav.history.Back); got != before {
		t.Fatalf("history lost the entry of a missing file: %d -> %d", before, got)
	}
}
