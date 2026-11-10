package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// treePromptFor opens one row's dialog in the test without a click: the dialog itself is
// declared by the next frame, and the action is what the test drives.
func treePromptFor(h *harness, p *project, kind treePromptKind, n *treeNode, name string) {
	h.t.Helper()
	h.app.openTreePrompt(p, kind, n)
	p.tree.prompt.name = name
}

func TestProjectTreeCreatesRenamesAndDeletes(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/keep.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	folder := p.tree.find("a")
	if folder == nil || !folder.dir {
		t.Fatalf("folder a is %+v", folder)
	}

	treePromptFor(h, p, treePromptNewFile, folder, "made.txt")
	h.app.submitTreePrompt(p)
	made := filepath.Join(root, "a", "made.txt")
	if _, err := os.Stat(made); err != nil {
		t.Fatalf("new file: %v", err)
	}
	h.await("the new file's row", func() bool { return p.tree.find("a/made.txt") != nil })
	h.await("the new file's tab", func() bool { return p.docs.byPath(made) != nil })

	node := p.tree.find("a/made.txt")
	treePromptFor(h, p, treePromptRename, node, "renamed.txt")
	h.app.submitTreePrompt(p)
	renamed := filepath.Join(root, "a", "renamed.txt")
	h.await("the renamed file", func() bool {
		_, err := os.Stat(renamed)
		return err == nil
	})
	if _, err := os.Stat(made); !os.IsNotExist(err) {
		t.Fatalf("the old name still exists: %v", err)
	}
	h.await("the renamed row", func() bool { return p.tree.find("a/renamed.txt") != nil })
	h.await("the tab at the new path", func() bool {
		d := p.docs.byPath(renamed)
		return d != nil && d.name == "renamed.txt"
	})

	// Deleting the folder saves and closes the tab below it and removes the file.
	folder = p.tree.find("a")
	treePromptFor(h, p, treePromptDelete, folder, "")
	h.app.submitTreePrompt(p)
	h.await("the deleted folder", func() bool {
		_, err := os.Stat(filepath.Join(root, "a"))
		return os.IsNotExist(err)
	})
	h.await("the deleted row", func() bool { return p.tree.find("a") == nil })
	h.await("the closed tab", func() bool { return p.docs.byPath(renamed) == nil })
}

func TestProjectTreePromptRejectsUnusableNames(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/keep.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	folder := p.tree.find("a")

	for _, name := range []string{"", "  ", ".", "..", "a/b", `a\b`} {
		treePromptFor(h, p, treePromptNewFile, folder, name)
		if got, ok := h.app.treeItemName(&p.tree.prompt); ok {
			t.Fatalf("name %q was accepted as %q", name, got)
		}
		if p.tree.prompt.err == "" {
			t.Fatalf("name %q was rejected without a reason", name)
		}
	}
	// A name an item already has is refused before the dialog closes.
	treePromptFor(h, p, treePromptNewFile, folder, "keep.txt")
	if _, ok := h.app.treeItemName(&p.tree.prompt); !ok {
		t.Fatal("a name without a slash was rejected")
	}
	p.tree.prompt.open = true
	h.app.submitTreePrompt(p)
	if p.tree.prompt.err == "" || !p.tree.prompt.open {
		t.Fatalf("an existing name left the dialog %+v", p.tree.prompt)
	}
}

func TestDocumentsUnderSpansOneFolder(t *testing.T) {
	a := &App{}
	p := &project{}
	p.docs.list = []*document{
		{path: "/work/a.txt"},
		{path: "/work/dir/b.txt"},
		{path: "/work/dir/sub/c.txt"},
		{path: "/work/dir2/d.txt"},
	}
	if got := len(a.documentsUnder(p, "/work/dir")); got != 2 {
		t.Fatalf("documentsUnder(/work/dir) = %d, want 2", got)
	}
	if got := len(a.documentsUnder(p, "/work/a.txt")); got != 1 {
		t.Fatalf("documentsUnder(a file) = %d, want 1", got)
	}
	if got := len(a.documentsUnder(p, "/work")); got != 4 {
		t.Fatalf("documentsUnder(the root) = %d, want 4", got)
	}
}

func TestTreeErrorReasonDropsThePath(t *testing.T) {
	err := &os.PathError{Op: "mkdir", Path: "/work/dir", Err: os.ErrPermission}
	reason := treeErrorReason(err)
	if reason != os.ErrPermission.Error() {
		t.Fatalf("reason %q", reason)
	}
	if strings.Contains(reason, "/work") {
		t.Fatalf("reason %q keeps the path", reason)
	}
}
