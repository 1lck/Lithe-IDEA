package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

func TestEvictingTabDuringRenameCheckAllowsProjectClose(t *testing.T) {
	root := t.TempDir()
	names := []string{"notes.txt", "b.txt", "c.txt", "d.txt", "e.txt", "readme.txt"}
	writeTreeFiles(t, root, names...)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	limit := len(names) - 1
	h.app.settings.EditorTabLimit = &limit
	h.app.settings.EditorTabPolicy = settingswindow.TabPolicyOldest
	for _, name := range names[:limit] {
		h.openTreeFileTab(p, filepath.Join(root, name))
	}
	h.settleChain()
	source := filepath.Join(root, names[0])
	doc := p.docs.byPath(source)
	entered, release := make(chan struct{}), make(chan struct{})
	signal := sync.OnceFunc(func() { close(entered) })
	unblock := sync.OnceFunc(func() { close(release) })
	defer unblock()
	h.app.documentReader = func(path string) ([]byte, error) {
		if path == source {
			signal()
			select {
			case <-release:
			case <-time.After(8 * time.Second):
				return nil, context.DeadlineExceeded
			}
		}
		return readDocument(path)
	}
	h.app.commitTreeMove(p, names[0], "renamed.txt")
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the rename did not start verifying the source")
	}
	// Queue another consumer while the same read is in flight. Eviction
	// must fail both without waiting for, or replaying, the stale read.
	var verified []bool
	h.app.checkBeforeClose(p, doc, func(ok bool) { verified = append(verified, ok) })
	h.openTreeFileTab(p, filepath.Join(root, names[limit]))
	if p.docs.byPath(source) != nil || !slices.Equal(verified, []bool{false}) {
		t.Fatalf("opening the next tab did not evict and abort verification: results=%v", verified)
	}
	unblock()
	h.settleChain()
	if !slices.Equal(verified, []bool{false}) {
		t.Fatalf("late disk check repeated verification: results=%v", verified)
	}
	expectTreeFileBytes(t, root, names[0], names[0]+"\n")
	if _, err := os.Lstat(filepath.Join(root, "renamed.txt")); !os.IsNotExist(err) {
		t.Fatalf("aborted rename left a destination: %v", err)
	}
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	h.await("the project to close after the source tab was evicted", func() bool { return closed })
}

type closeWithMovedTabKernel struct {
	*closeDuringTreeMoveKernel
	savePlans int
}

func (k *closeWithMovedTabKernel) PlanDocumentSaveBatch(ctx context.Context, docs []core.SaveBatchDocument) (core.SaveBatchPlan, error) {
	k.savePlans++
	return k.Client.PlanDocumentSaveBatch(ctx, docs)
}

func TestProjectCloseVerifiesMovedTabAfterRenameReceipt(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "before/note.txt")
	k := &closeWithMovedTabKernel{closeDuringTreeMoveKernel: &closeDuringTreeMoveKernel{
		testKernel: &testKernel{Client: core.NewClient()}, hold: "rename receipt",
		entered: make(chan struct{}), release: make(chan struct{}),
	}}
	h := newHarness(t, k)
	p := h.openTree(t, root)
	h.openTreeFileTab(p, filepath.Join(root, "before", "note.txt"))
	unblock := sync.OnceFunc(func() { close(k.release) })
	defer unblock()
	h.app.commitTreeMove(p, "before", "after")
	k.awaitGate(t, h)
	before := k.savePlans
	closed := false
	h.app.requestCloseProject(func() { closed = true })
	if k.savePlans != before || closed {
		t.Fatal("close started verifying the old tab path before the rename receipt")
	}
	unblock()
	h.await("close after the tab follows the rename", func() bool { return closed })
	var saved map[string]savedEditorSession
	if ok, err := h.store.Load(editorSessionFile, &saved); !ok || err != nil {
		t.Fatalf("saved editor session missing: %v", err)
	}
	groups := saved[root].Groups
	if len(groups) != 1 || len(groups[0].Files) != 1 || groups[0].Files[0].Path != "after/note.txt" {
		t.Fatalf("expected the moved tab in the saved session: %+v", groups)
	}
}
