package workbench

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// writeTreeFiles makes the files at the slash-separated paths under root, with the folders
// above them.
func writeTreeFiles(t *testing.T, root string, paths ...string) {
	t.Helper()
	for _, name := range paths {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(name+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// openTree opens the project at root and waits for its tree's root listing.
func (h *harness) openTree(t *testing.T, root string) *project {
	t.Helper()
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	h.settle()
	return p
}

// treeAction is the hit the last frame declared for the header button action of the Project
// tool window.
func (h *harness) treeAction(action int) gfx.Hit {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == treeActionLabel(h, action) && !hit.IsLabel {
			return hit
		}
	}
	h.t.Fatalf("no header button %d in the project tree", action)
	return gfx.Hit{}
}

// treeIdle says no listing of the tree is asked for or being read.
func treeIdle(p *project) bool { return !p.tree.reading && len(p.tree.pending) == 0 }

func TestProjectTreeLocatesTheActiveFile(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/b/c.go", "a/other.txt", "top.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	if !h.treeAction(treeActionLocate).Disabled {
		t.Fatal("locate is enabled with no file open")
	}
	h.app.openFile(p, filepath.Join(root, "a", "b", "c.go"))
	awaitDocumentState(t, h, func() bool { _, ok := activeTreePath(p); return ok })
	h.settle()
	locate := h.treeAction(treeActionLocate)
	if locate.Disabled || locate.Label != "在项目树中定位当前文件" {
		t.Fatalf("locate button %+v", locate)
	}
	h.click(center(locate.Bounds))
	awaitDocumentState(t, h, func() bool { return p.tree.selected != nil && p.tree.selected.path == "a/b/c.go" })
	for _, dir := range []string{"a", "a/b"} {
		if n := p.tree.find(dir); n == nil || !n.expanded || !n.listed {
			t.Fatalf("folder %s above the located file is %+v", dir, n)
		}
	}
	if p.tree.reveal != "" || p.tree.revealAsked != nil {
		t.Fatalf("locating did not end: %q", p.tree.reveal)
	}
	h.settle()
	if i := p.tree.view.Selected(); i < 0 || p.tree.rows[i] != p.tree.selected {
		t.Fatalf("the located row is not the tree's current row: %d", i)
	}
}

func TestProjectTreeLocateGivesUpOnAFileThatIsGone(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/gone.go", "a/kept.go")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	h.app.openFile(p, filepath.Join(root, "a", "gone.go"))
	awaitDocumentState(t, h, func() bool { _, ok := activeTreePath(p); return ok })
	if err := os.Remove(filepath.Join(root, "a", "gone.go")); err != nil {
		t.Fatal(err)
	}
	selected := p.tree.selected
	h.app.revealActiveFile(p)
	awaitDocumentState(t, h, func() bool { return p.tree.reveal == "" && treeIdle(p) })
	if p.tree.selected != selected {
		t.Fatalf("locating a file that is gone selected %+v", p.tree.selected)
	}
	if n := p.tree.find("a"); n == nil || !n.expanded || p.tree.find("a/kept.go") == nil {
		t.Fatalf("the folder of the file that is gone did not open: %+v", n)
	}
}

func TestProjectTreeExpandsAndCollapsesAll(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "a/b/c/x.go", "a/y.go", "d/z.go", "top.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	folders := []string{"a", "a/b", "a/b/c", "d"}

	h.click(center(h.treeAction(treeActionExpand).Bounds))
	awaitDocumentState(t, h, func() bool { return !p.tree.expandingAll })
	for _, dir := range folders {
		if n := p.tree.find(dir); n == nil || !n.expanded || !n.listed {
			t.Fatalf("Expand All left %s as %+v", dir, n)
		}
	}
	h.settle()
	if h.treeAction(treeActionExpand).Disabled {
		t.Fatal("Expand All stayed disabled after it ended")
	}

	p.tree.selected = p.tree.find("a/b/c/x.go")
	h.click(center(h.treeAction(treeActionCollapse).Bounds))
	for _, dir := range folders {
		if n := p.tree.find(dir); n == nil || n.expanded {
			t.Fatalf("Collapse All left %s open", dir)
		}
	}
	if !p.tree.root.expanded {
		t.Fatal("Collapse All closed the root")
	}
	h.settle()
	if a := p.tree.find("a"); p.tree.selected != a {
		t.Fatalf("the hidden selection moved to %+v", p.tree.selected)
	}
	if rows := len(p.tree.rows); rows != 4 {
		t.Fatalf("Collapse All shows %d rows, want the root and its three entries", rows)
	}
}

func TestProjectTreeExpandAllStopsAtItsLimit(t *testing.T) {
	root := t.TempDir()
	count := treeExpandAllLimit + 2
	paths := make([]string, count)
	for i := range paths {
		paths[i] = fmt.Sprintf("d%04d/f.txt", i)
	}
	writeTreeFiles(t, root, paths...)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	// Observe this action's notice before unrelated native watcher completions
	// can replace the single banner (Linux reaches its separate watch cap first).
	// The button dispatch is exercised by TestProjectTreeExpandsAndCollapsesAll.
	h.app.expandProjectTree(p)
	if p.tree.expandingAll {
		t.Fatal("Expand All went on past its limit")
	}
	if want := i18n.Shared(h.app.language(), "desktop.project.expandAllIncomplete"); h.app.notice != want {
		t.Fatalf("notice %q, want %q", h.app.notice, want)
	}
	expanded := 0
	for _, child := range p.tree.root.children {
		if child.expanded {
			expanded++
		}
	}
	if expanded != treeExpandAllLimit {
		t.Fatalf("Expand All opened %d folders, want %d", expanded, treeExpandAllLimit)
	}
	awaitDocumentState(t, h, func() bool { return treeIdle(p) })
}

// recordingTreeKernel records the folders each listing asks for.
type recordingTreeKernel struct {
	*testKernel
	mu       sync.Mutex
	requests [][]string
}

func (k *recordingTreeKernel) ListDirectories(ctx context.Context, root string, paths []string) ([]core.DirectoryListing, error) {
	k.mu.Lock()
	k.requests = append(k.requests, slices.Clone(paths))
	k.mu.Unlock()
	return k.testKernel.ListDirectories(ctx, root, paths)
}

// since is every folder the listings asked for after the first n requests.
func (k *recordingTreeKernel) since(n int) []string {
	k.mu.Lock()
	defer k.mu.Unlock()
	var paths []string
	for _, request := range k.requests[n:] {
		paths = append(paths, request...)
	}
	slices.Sort(paths)
	return paths
}

func (k *recordingTreeKernel) count() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.requests)
}

func TestProjectTreeRefreshReadsTheOpenFoldersAgain(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "open/a.go", "closed/b.go")
	kernel := &recordingTreeKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	p := h.openTree(t, root)
	open := p.tree.find("open")
	h.app.toggleFolder(p, open)
	awaitDocumentState(t, h, func() bool { return open.listed && treeIdle(p) })
	h.settle()

	// The button is disabled for as long as the refresh reads.
	before := kernel.count()
	h.app.refreshProjectTree(p)
	if !p.tree.refreshing {
		t.Fatal("the refresh did not start")
	}
	awaitDocumentState(t, h, func() bool { return !p.tree.refreshing })
	if got := kernel.since(before); !slices.Contains(got, "") || !slices.Contains(got, "open") || slices.Contains(got, "closed") {
		t.Fatalf("refresh listed %q, want the root and the open folder", got)
	}
	h.settle()
	refresh := h.treeAction(treeActionRefresh)
	if refresh.Disabled || refresh.Label != "刷新" {
		t.Fatalf("refresh button after it ended: %+v", refresh)
	}
	before = kernel.count()
	h.click(center(refresh.Bounds))
	awaitDocumentState(t, h, func() bool { return !p.tree.refreshing && treeIdle(p) })
	if got := kernel.since(before); !slices.Contains(got, "open") {
		t.Fatalf("the refresh button listed %q", got)
	}
}

func TestProjectTreeRefreshRetriesARootThatIsGone(t *testing.T) {
	root := filepath.Join(t.TempDir(), "workspace")
	writeTreeFiles(t, root, "first.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	if err := os.RemoveAll(root); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.failed != "" })
	h.settle()
	for _, action := range []int{treeActionLocate, treeActionExpand, treeActionCollapse} {
		if !h.treeAction(action).Disabled {
			t.Fatalf("header button %d is enabled without a tree", action)
		}
	}
	writeTreeFiles(t, root, "restored.txt")
	h.click(center(h.treeAction(treeActionRefresh).Bounds))
	awaitDocumentState(t, h, func() bool { return p.tree.failed == "" && p.tree.find("restored.txt") != nil })
}

// treeRowHit is the hit of the tree's row named name, the control the Tree declared for it.
func (h *harness) treeRowHit(name string) gfx.Hit {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == name && !hit.IsLabel && hit.Bounds.Width > 100 && h.treeRowOwned(hit.ID) {
			return hit
		}
	}
	h.t.Fatalf("the tree shows no row named %q", name)
	return gfx.Hit{}
}

// treeNameHit is the hit over the name of the tree's row named name, narrower than the row and
// after its chevron.
func (h *harness) treeNameHit(name string) gfx.Hit {
	h.t.Helper()
	row := h.treeRowHit(name).Bounds
	for _, hit := range h.driver.Snapshot().Hits {
		b := hit.Bounds
		if hit.Label == name && b.Width > 0 && b.Width < row.Width/2 && b.X > row.X+treeChevron &&
			b.Y >= row.Y && b.Y+b.Height <= row.Y+row.Height {
			return hit
		}
	}
	h.t.Fatalf("the tree shows no name hit for %q", name)
	return gfx.Hit{}
}

// treeRowCount is how many rows the tree declared in the last paint.
func (h *harness) treeRowCount() int {
	n := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleButton && !hit.IsLabel && hit.Bounds.Width > 100 && h.treeRowOwned(hit.ID) {
			n++
		}
	}
	return n
}

// treeChevronHit is the hit of the chevron of the folder named name.
func (h *harness) treeChevronHit(name string) gfx.Hit {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == name && !hit.IsLabel && hit.Bounds.Width <= 40 && h.treeRowOwned(hit.ID) {
			return hit
		}
	}
	h.t.Fatalf("the tree shows no chevron for %q", name)
	return gfx.Hit{}
}

// treeActionLabel is the name of the header button action of the Project tool window.
func treeActionLabel(h *harness, action int) string {
	language := h.app.language()
	switch action {
	case treeActionLocate:
		return i18n.Shared(language, "native.revealActiveFileInProjectTree")
	case treeActionRefresh:
		return i18n.Shared(language, "ui.refresh")
	case treeActionExpand:
		return i18n.Shared(language, "outline.expandAll")
	}
	return i18n.Shared(language, "files.collapseAll")
}

// treeRowOwned says id is the identity of one of the tree's rows or chevrons.
func (h *harness) treeRowOwned(id gfx.ID) bool {
	t := &h.app.project.tree
	for i := range t.rows {
		if t.view.RowID(i) == id || t.view.DisclosureID(i) == id {
			return true
		}
	}
	return false
}
