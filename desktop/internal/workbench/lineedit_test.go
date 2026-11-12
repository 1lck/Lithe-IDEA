package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func TestLineOperationKeys(t *testing.T) {
	primary := gfx.ModifierControl
	cases := []struct {
		name  string
		event gfx.KeyEvent
		want  core.LineEditOperation
		ok    bool
	}{
		{"move up", gfx.KeyEvent{Key: gfx.KeyUp, Modifiers: gfx.ModifierAlt}, core.MoveLineUp, true},
		{"move down", gfx.KeyEvent{Key: gfx.KeyDown, Modifiers: gfx.ModifierAlt}, core.MoveLineDown, true},
		{"copy up", gfx.KeyEvent{Key: gfx.KeyUp, Modifiers: gfx.ModifierAlt | gfx.ModifierShift}, core.CopyLineUp, true},
		{"copy down", gfx.KeyEvent{Key: gfx.KeyDown, Modifiers: gfx.ModifierAlt | gfx.ModifierShift}, core.CopyLineDown, true},
		{"comment", gfx.KeyEvent{Text: "/", Modifiers: primary}, core.ToggleLineComment, true},
		{"delete", gfx.KeyEvent{Text: "K", Modifiers: primary | gfx.ModifierShift}, core.DeleteLine, true},
		{"plain arrow", gfx.KeyEvent{Key: gfx.KeyDown}, "", false},
		{"release", gfx.KeyEvent{Key: gfx.KeyDown, Modifiers: gfx.ModifierAlt, Release: true}, "", false},
	}
	for _, tc := range cases {
		got, ok := lineOperationFor(tc.event, primary)
		if got != tc.want || ok != tc.ok {
			t.Errorf("%s: got %q %v", tc.name, got, ok)
		}
	}
}

func TestLineOperationsThroughCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "main.go")
	if err := os.WriteFile(path, []byte("one\ntwo\nthree\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	if doc == nil {
		t.Fatal("document did not open")
	}
	awaitDocumentState(t, h, func() bool { return doc.view.Owns(h.driver.Snapshot().Focused) })
	doc.view.SetSelection(5, 5) // inside "two"
	run := func(op core.LineEditOperation) {
		t.Helper()
		h.app.runLineOperation(p, doc, op)
		h.settle()
	}
	run(core.MoveLineDown)
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\ntwo\n" {
		t.Fatalf("move down = %q", got)
	}
	run(core.ToggleLineComment)
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\n// two\n" {
		t.Fatalf("comment = %q", got)
	}
	run(core.DeleteLine)
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\n" {
		t.Fatalf("delete = %q", got)
	}
	doc.view.Undo()
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\n// two\n" {
		t.Fatalf("undo = %q", got)
	}
	doc.view.SetSelection(0, 0)
	run(core.MoveLineUp) // first line: a no-op
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\n// two\n" {
		t.Fatalf("no-op = %q", got)
	}
}

func TestEditorContextMenuRunsLineOperation(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "main.go")
	if err := os.WriteFile(path, []byte("one\ntwo\nthree\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	awaitDocumentState(t, h, func() bool { return doc.view.Owns(h.driver.Snapshot().Focused) })
	var at gfx.Point
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == doc.hit {
			at = center(hit.Bounds)
		}
	}
	if err := h.driver.ClickButton(at.X, at.Y, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !h.shows("Go to Definition") || !h.shows("Delete Line") {
		t.Fatalf("the context menu did not open: %v", h.driver.Snapshot().Labels)
	}
	doc.view.SetSelection(5, 5)
	h.clickNamed("Delete Line")
	h.settle()
	if got := doc.view.TextSnapshot().String(); got != "one\nthree\n" {
		t.Fatalf("text = %q", got)
	}
}
