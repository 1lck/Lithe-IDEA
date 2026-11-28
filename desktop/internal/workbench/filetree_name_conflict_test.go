package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// writeTreeFiles gives each file different bytes: its original relative path and a newline.
func expectTreeFileBytes(t *testing.T, root, path, want string) {
	t.Helper()
	got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
	if err != nil || string(got) != want {
		t.Errorf("%s: got %q, %v; want %q", path, got, err, want)
	}
}

func (h *harness) openTreeFileTab(p *project, path string) *document {
	h.t.Helper()
	h.app.openFile(p, path)
	h.await("open tab for "+path, func() bool {
		d := p.selectedDocument(p.docs.group)
		return d != nil && d.path == path && !d.checking && !d.checkPending
	})
	return p.selectedDocument(p.docs.group)
}

// Both entries exist before the project is opened; this exercises an ordinary name conflict.
func TestProjectTreeRenameOntoExistingFile(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "map.txt", "map.txt.bak")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)

	h.rightClickNamed("map.txt")
	h.popupClick(h.shared("desktop.files.rename"))
	h.clickNamed(h.shared("desktop.files.name"))
	h.key(gfx.KeyEnd)
	h.typeText(".bak")
	h.clickNamed(h.shared("desktop.files.renameAction"))

	h.await("the rename conflict message", func() bool { return h.shows(h.shared("desktop.files.nameExists")) })
	if !h.hasControl(h.shared("desktop.files.renameAction")) {
		t.Error("the rename dialog closed instead of letting the user choose another name")
	}
	expectTreeFileBytes(t, root, "map.txt", "map.txt\n")
	expectTreeFileBytes(t, root, "map.txt.bak", "map.txt.bak\n")
}

func TestProjectTreeCaseOnlyRenameKeepsOpenTab(t *testing.T) {
	const oldName, newName = "map.txt", "Map.txt"
	root := t.TempDir()
	writeTreeFiles(t, root, oldName)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	tab := h.openTreeFileTab(p, filepath.Join(root, oldName))

	treePromptFor(h, p, treePromptRename, p.tree.find(oldName), newName)
	h.app.submitTreePrompt(p)
	newPath := filepath.Join(root, newName)
	h.await("the case-renamed tab and tree row", func() bool {
		return tab.path == newPath && p.tree.find(newName) != nil
	})

	// On a case-insensitive volume, looking up either spelling finds the file.
	// The parent directory records the spelling the rename actually left behind.
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if !slices.Contains(names, newName) || slices.Contains(names, oldName) {
		t.Errorf("directory entries %q; want %q and not %q", names, newName, oldName)
	}
	expectTreeFileBytes(t, root, newName, oldName+"\n")
	if p.selectedDocument(p.docs.group) != tab || tab.name != newName {
		t.Errorf("the original tab did not follow the rename: path %q, title %q", tab.path, tab.name)
	}
}

func TestProjectTreeDragOntoExistingFile(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "leaf.txt", "box/leaf.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)

	h.drag(center(h.treeNameHit("leaf.txt").Bounds), center(h.treeNameHit("box").Bounds))
	h.settleChain()

	expectTreeFileBytes(t, root, "leaf.txt", "leaf.txt\n")
	expectTreeFileBytes(t, root, "box/leaf.txt", "box/leaf.txt\n")
	if !h.shows(h.shared("desktop.files.nameExists")) {
		t.Error("dropping onto a folder containing the name showed no conflict notice")
	}
}

func TestProjectTreeDragIntoAvailableName(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "leaf.txt", "box/keep.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)

	h.drag(center(h.treeNameHit("leaf.txt").Bounds), center(h.treeNameHit("box").Bounds))
	h.settleChain()

	expectTreeFileBytes(t, root, "box/leaf.txt", "leaf.txt\n")
	expectTreeFileBytes(t, root, "box/keep.txt", "box/keep.txt\n")
	if _, err := os.Lstat(filepath.Join(root, "leaf.txt")); !os.IsNotExist(err) {
		t.Errorf("expected the old path to be absent after the move, got %v", err)
	}
	if h.shows(h.shared("desktop.files.nameExists")) {
		t.Error("a successful move showed a name conflict")
	}
}
