package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// stubTreeTrash replaces the system trash for one test and returns the paths moved to it, so a
// test never fills the trash of the machine running it. The stub removes what it is given, as
// the trash takes it out of the folder.
func stubTreeTrash(t *testing.T) *[]string {
	t.Helper()
	var trashed []string
	var mu sync.Mutex
	previous := treeMoveToTrash
	treeMoveToTrash = func(full string) error {
		mu.Lock()
		trashed = append(trashed, full)
		mu.Unlock()
		return os.RemoveAll(full)
	}
	t.Cleanup(func() { treeMoveToTrash = previous })
	return &trashed
}

// Delete is one menu item; its dialog moves the item to the trash by default and offers
// Delete Permanently beside it, as the IDE does.
func TestProjectTreeDeleteMovesToTheTrashByDefault(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/keep.txt", "b.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	trashed := stubTreeTrash(t)

	h.rightClickNamed("b.txt")
	if h.hasPopupItem(h.shared("desktop.files.moveToTrash")) {
		t.Fatal("the menu still lists Move to Trash beside Delete")
	}
	h.click(center(h.popupHit(h.shared("desktop.files.delete"))))
	h.settle()
	if !p.tree.removal.open || !slices.Equal(p.tree.removal.paths, []string{"b.txt"}) {
		t.Fatalf("Delete opened %+v, want the dialog for b.txt", p.tree.removal)
	}
	h.clickNamed(h.shared("desktop.files.moveToTrash"))
	h.await("the trashed row", func() bool { return p.tree.find("b.txt") == nil })
	if want := []string{filepath.Join(root, "b.txt")}; !slices.Equal(*trashed, want) {
		t.Fatalf("trashed %v, want %v", *trashed, want)
	}
	if p.tree.removal.open {
		t.Fatal("the Delete dialog stayed open")
	}
}

// Copy Path and Copy Relative Path sit in one submenu of the tree row, as in the tab menu.
func TestProjectTreeCopyPathSubmenu(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/keep.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)

	h.rightClickNamed("a")
	if h.hasPopupItem(h.shared("native.copyRelativePath")) {
		t.Fatal("Copy Relative Path is still a top-level item")
	}
	h.clickNamed(h.shared("native.copyPathReference"))
	h.clickNamed(h.shared("native.copyRelativePath"))
	if got := h.driver.Clipboard(); got != "a" {
		t.Fatalf("copied relative path %q, want a", got)
	}
}

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

	// Delete Permanently in the Delete dialog saves and closes the tab below the folder and
	// removes the folder from disk.
	// Opening the dialog only changes state, so ask for a frame and wait until the dialog is
	// in it: a frame drawn before then has no Delete Permanently button to click.
	h.app.openTreeRemoval(p, []string{"a"})
	h.app.invalidator.Invalidate()
	h.settle()
	deletePermanently := h.shared("desktop.files.deletePermanently")
	h.await("the Delete dialog", func() bool {
		_, ok := h.findPageHit(deletePermanently)
		return ok
	})
	h.clickNamed(deletePermanently)
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
	// Document paths use the platform separator, as the window builds them with filepath.
	path := filepath.FromSlash
	p.docs.list = []*document{
		{path: path("/work/a.txt")},
		{path: path("/work/dir/b.txt")},
		{path: path("/work/dir/sub/c.txt")},
		{path: path("/work/dir2/d.txt")},
	}
	if got := len(a.documentsUnder(p, path("/work/dir"))); got != 2 {
		t.Fatalf("documentsUnder(/work/dir) = %d, want 2", got)
	}
	if got := len(a.documentsUnder(p, path("/work/a.txt"))); got != 1 {
		t.Fatalf("documentsUnder(a file) = %d, want 1", got)
	}
	if got := len(a.documentsUnder(p, path("/work"))); got != 4 {
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
