package workbench

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// changeOnWindow runs a file change of the plugin API while the test pumps the window.
func changeOnWindow(h *harness, what string, change func(ctx context.Context) error) error {
	h.t.Helper()
	_, err := callOnWindow(h, what, func(ctx context.Context) (struct{}, error) {
		return struct{}{}, change(ctx)
	})
	return err
}

// pluginEdit replaces the whole first line of d through the plugin API and returns the version
// after it.
func pluginEdit(t *testing.T, h *harness, root string, d *document, text string) int {
	t.Helper()
	w := pluginWorkbench{app: h.app}
	result, err := callOnWindow(h, "edit", func(ctx context.Context) (pluginservice.EditResult, error) {
		return w.Edit(ctx, root, pluginservice.EditRequest{DocumentID: documentPublicID(d), ExpectedVersion: d.view.Revision(), Edits: []pluginservice.RangeEdit{{
			Range: pluginservice.Range{Start: pluginservice.Position{Line: 1, Column: 1}, End: pluginservice.Position{Line: 1, Column: 6}}, Text: text}}})
	})
	if err != nil || !result.Applied {
		t.Fatalf("edit = %+v, %v", result, err)
	}
	return result.Version
}

func readText(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// A save writes the document's current text; a stale version is refused with the current one.
func TestPluginSaveWritesTheCurrentTextAtTheExpectedVersion(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, d := openNote(t, h, "alpha")
	w := pluginWorkbench{app: h.app}
	version := pluginEdit(t, h, root, d, "ALPHA")
	stale := version - 1
	_, err := callOnWindow(h, "stale save", func(ctx context.Context) (pluginservice.DocumentSummary, error) {
		return w.SaveDocument(ctx, root, documentPublicID(d), &stale)
	})
	if hostErrorCode(err) != pluginservice.CodeVersionConflict || readText(t, d.path) != "alpha" {
		t.Fatalf("stale save = %v, disk %q", err, readText(t, d.path))
	}
	saved, err := callOnWindow(h, "save", func(ctx context.Context) (pluginservice.DocumentSummary, error) {
		return w.SaveDocument(ctx, root, documentPublicID(d), &version)
	})
	if err != nil || saved.IsDirty || readText(t, d.path) != "ALPHA" {
		t.Fatalf("save = %+v, %v, disk %q", saved, err, readText(t, d.path))
	}
}

// Save As has Core write a new file with the text and opens it; the document stays open, and a
// target that exists is refused without touching it.
func TestPluginSaveAsCreatesTheFileAndOpensIt(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, d := openNote(t, h, "alpha")
	w := pluginWorkbench{app: h.app}
	pluginEdit(t, h, root, d, "ALPHA")
	copied, err := callOnWindow(h, "save as", func(ctx context.Context) (pluginservice.DocumentSummary, error) {
		return w.SaveDocumentAs(ctx, root, documentPublicID(d), "copy.txt")
	})
	if err != nil || copied.Path == nil || *copied.Path != "copy.txt" || copied.IsDirty {
		t.Fatalf("save as = %+v, %v", copied, err)
	}
	if readText(t, filepath.Join(root, "copy.txt")) != "ALPHA" {
		t.Fatal("save as did not write the text")
	}
	if h.app.project.docs.find(d.id) != d || h.app.project.docs.byPath(filepath.Join(root, "copy.txt")) == nil {
		t.Fatal("save as did not keep the document and open the new file")
	}
	taken := filepath.Join(root, "taken.txt")
	if err := os.WriteFile(taken, []byte("taken"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = callOnWindow(h, "save as onto a file", func(ctx context.Context) (pluginservice.DocumentSummary, error) {
		return w.SaveDocumentAs(ctx, root, documentPublicID(d), "taken.txt")
	})
	if hostErrorCode(err) != pluginservice.CodeAlreadyExists || readText(t, taken) != "taken" {
		t.Fatalf("save as onto a file = %v", err)
	}
}

// Core creates files, folders and links without replacing anything, and copies a file.
func TestPluginCreateAndCopyGoThroughCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	w := pluginWorkbench{app: h.app}
	text := "hi"
	create := func(entry pluginservice.EntryCreation) error {
		return changeOnWindow(h, "create "+entry.Path, func(ctx context.Context) error { return w.CreateEntry(ctx, root, entry) })
	}
	if err := create(pluginservice.EntryCreation{Path: "a.txt", Kind: "file", Text: &text}); err != nil {
		t.Fatal(err)
	}
	if err := create(pluginservice.EntryCreation{Path: "dir", Kind: "directory"}); err != nil {
		t.Fatal(err)
	}
	if readText(t, filepath.Join(root, "a.txt")) != "hi" {
		t.Fatal("the file was not created with its text")
	}
	if info, err := os.Stat(filepath.Join(root, "dir")); err != nil || !info.IsDir() {
		t.Fatalf("the folder was not created: %v", err)
	}
	if err := create(pluginservice.EntryCreation{Path: "a.txt", Kind: "file", Text: &text}); hostErrorCode(err) != pluginservice.CodeAlreadyExists {
		t.Fatalf("creating an existing file = %v", err)
	}
	if err := create(pluginservice.EntryCreation{Path: "missing/b.txt", Kind: "file", Text: &text}); hostErrorCode(err) != pluginservice.CodeNotFound {
		t.Fatalf("creating in a missing folder = %v", err)
	}
	if runtime.GOOS != "windows" {
		// Windows creates links only in developer mode or as an administrator; Core's own tests
		// cover it there.
		target := "a.txt"
		if err := create(pluginservice.EntryCreation{Path: "link", Kind: "symlink", LinkTarget: &target}); err != nil {
			t.Fatal(err)
		}
		if stored, err := os.Readlink(filepath.Join(root, "link")); err != nil || stored != "a.txt" {
			t.Fatalf("link = %q, %v", stored, err)
		}
	}
	if err := changeOnWindow(h, "copy", func(ctx context.Context) error { return w.CopyEntry(ctx, root, "a.txt", "dir/a.txt") }); err != nil {
		t.Fatal(err)
	}
	if readText(t, filepath.Join(root, "dir", "a.txt")) != "hi" {
		t.Fatal("the copy does not have the file's text")
	}
	if err := changeOnWindow(h, "copy onto a file", func(ctx context.Context) error { return w.CopyEntry(ctx, root, "a.txt", "dir/a.txt") }); hostErrorCode(err) != pluginservice.CodeAlreadyExists {
		t.Fatalf("copying onto a file = %v", err)
	}
}

// A rename saves the open document first, moves it with its file, and is refused when the target
// exists.
func TestPluginRenameSavesAndMovesTheOpenDocument(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, d := openNote(t, h, "alpha")
	w := pluginWorkbench{app: h.app}
	if err := os.Mkdir(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "taken.txt"), []byte("taken"), 0o600); err != nil {
		t.Fatal(err)
	}
	pluginEdit(t, h, root, d, "ALPHA")
	rename := func(from, to string) error {
		return changeOnWindow(h, "rename "+from, func(ctx context.Context) error { return w.RenameEntry(ctx, root, from, to) })
	}
	if err := rename("note.txt", "taken.txt"); hostErrorCode(err) != pluginservice.CodeAlreadyExists || readText(t, filepath.Join(root, "taken.txt")) != "taken" {
		t.Fatalf("renaming onto a file = %v", err)
	}
	if err := rename("gone.txt", "sub/gone.txt"); hostErrorCode(err) != pluginservice.CodeNotFound {
		t.Fatalf("renaming a missing file = %v", err)
	}
	if err := rename("note.txt", "sub/moved.txt"); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(root, "sub", "moved.txt")
	if readText(t, moved) != "ALPHA" {
		t.Fatal("the edits were not saved before the rename")
	}
	if _, err := os.Lstat(filepath.Join(root, "note.txt")); !os.IsNotExist(err) {
		t.Fatalf("the old file is still there: %v", err)
	}
	if h.app.project.docs.byPath(moved) != d || d.dirty() {
		t.Fatal("the open document did not follow its file")
	}
}

// Trash saves and closes the documents under the folder and hands the folder to the trash.
func TestPluginTrashClosesTheDocumentsUnderTheEntry(t *testing.T) {
	trashed := stubTreeTrash(t)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	dir := filepath.Join(root, "dir")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(path, []byte("alpha"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the file did not open")
	}
	w := pluginWorkbench{app: h.app}
	pluginEdit(t, h, root, d, "ALPHA")
	if err := changeOnWindow(h, "trash a missing entry", func(ctx context.Context) error { return w.TrashEntry(ctx, root, "gone") }); hostErrorCode(err) != pluginservice.CodeNotFound {
		t.Fatalf("trashing a missing entry = %v", err)
	}
	if err := changeOnWindow(h, "trash", func(ctx context.Context) error { return w.TrashEntry(ctx, root, "dir") }); err != nil {
		t.Fatal(err)
	}
	if len(*trashed) != 1 || (*trashed)[0] != dir {
		t.Fatalf("trashed %v, want %s", *trashed, dir)
	}
	if h.app.project.docs.find(d.id) != nil {
		t.Fatal("the document under the folder is still open")
	}
}
