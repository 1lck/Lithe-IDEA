package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

func TestProjectSearchOpensMatchingLine(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	path := filepath.Join(root, "example.go")
	if err := os.WriteFile(path, []byte("first\nsecond needle\nthird\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.click(center(h.button(itemFind)))
	if err := h.driver.Click(center(h.hit(searchQueryID)).X, center(h.hit(searchQueryID)).Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("needle"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) > 0 })
	if p.search.matches[0].Line == nil || *p.search.matches[0].Line != 2 {
		t.Fatalf("results = %+v", p.search.matches)
	}
	h.clickNamed(searchMatchLabel(p.search.matches[0]))
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(path) != nil })
	if line, _ := p.docs.byPath(path).view.Caret(); line != 1 {
		t.Fatalf("opened line = %d, want 1 (zero-based)", line)
	}
}

type delayedSearchKernel struct {
	*testKernel
	started chan string
	release chan struct{}
}

func (k *delayedSearchKernel) InvalidateWorkspaceSearch(context.Context, string) error { return nil }
func (k *delayedSearchKernel) SearchWorkspace(_ context.Context, request core.WorkspaceSearchRequest) ([]core.WorkspaceSearchMatch, error) {
	k.started <- request.Query
	if request.Query == "first" {
		<-k.release
	}
	return []core.WorkspaceSearchMatch{{Path: request.Query}}, nil
}

func TestProjectSearchCancelsAndSerializesSupersededQueries(t *testing.T) {
	k := &delayedSearchKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan string, 2), release: make(chan struct{})}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	released := false
	defer func() {
		if !released {
			close(k.release)
		}
	}()
	h.app.updateProjectSearch(p, searchQuery{text: "first"})
	awaitDocumentState(t, h, func() bool { return p.search.running })
	select {
	case got := <-k.started:
		if got != "first" {
			t.Fatal(got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("first search did not start")
	}
	h.app.updateProjectSearch(p, searchQuery{text: "second"})
	select {
	case got := <-k.started:
		t.Fatalf("overlapping search started: %s", got)
	default:
	}
	close(k.release)
	released = true
	awaitDocumentState(t, h, func() bool {
		return !p.search.loading && len(p.search.matches) == 1 && p.search.matches[0].Path == "second"
	})
	select {
	case got := <-k.started:
		if got != "second" {
			t.Fatal(got)
		}
	default:
		t.Fatal("latest search did not run")
	}
}

func TestProjectSearchOptionsAndMaskUseCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "one.go"), []byte("NEEDLE\nneedle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "two.txt"), []byte("needle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.click(center(h.button(itemFind)))
	at := center(h.hit(searchQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("needle"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 3 })
	h.clickShared("native.searchOptions")
	h.clickShared("native.matchCase")
	if err := h.driver.Advance(time.Second / 30); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && p.search.want.matchCase && len(p.search.matches) == 2 })
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	at = center(h.hit(searchMaskID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("*.go"); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && p.search.want.mask == "*.go" && len(p.search.matches) == 1 })
	if p.search.matches[0].Path != "one.go" || p.search.matches[0].Line == nil || *p.search.matches[0].Line != 2 {
		t.Fatalf("filtered results = %+v", p.search.matches)
	}
	if err := os.WriteFile(filepath.Join(root, "one.go"), []byte("updated needle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.clickShared("ui.refresh")
	awaitDocumentState(t, h, func() bool {
		return !p.search.loading && len(p.search.matches) == 1 && p.search.matches[0].Line != nil && *p.search.matches[0].Line == 1
	})
	h.clickClear(1)
	if err := h.driver.Advance(time.Second / 30); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && p.search.want.mask == "" })
	h.clickClear(0)
	if err := h.driver.Advance(time.Second / 30); err != nil {
		t.Fatal(err)
	}
	if h.app.searchView.query.Text() != "" {
		t.Fatal("clear button retained the search query")
	}
}

func TestProjectSearchTracksExternalChanges(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	path := filepath.Join(root, "file.txt")
	if err := os.WriteFile(path, []byte("needle one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.click(center(h.button(itemFind)))
	at := center(h.hit(searchQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("needle"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.search.watchReady && !p.search.loading && len(p.search.matches) == 1 })
	if !p.search.watchAvailable {
		t.Skip("recursive filesystem notifications are unavailable")
	}
	if err := os.WriteFile(path, []byte("other text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 0 })
	dir := filepath.Join(root, "nested")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("needle two\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool {
		return !p.search.loading && len(p.search.matches) == 1 && p.search.matches[0].Path == "nested/new.txt"
	})
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 0 })
	h.app.cancelProjectSearch(p)
	if p.search.watchAttached || (p.search.watch != nil && !p.tree.recursiveWatch) {
		t.Fatal("closing search retained its filesystem watch")
	}
}

type cleanupSearchKernel struct {
	*testKernel
	invalidations atomic.Int32
}

func (k *cleanupSearchKernel) InvalidateWorkspaceSearch(context.Context, string) error {
	k.invalidations.Add(1)
	return nil
}
func (k *cleanupSearchKernel) SearchWorkspace(context.Context, core.WorkspaceSearchRequest) ([]core.WorkspaceSearchMatch, error) {
	return nil, nil
}

func TestProjectSearchDropsIndexWhenProjectCloses(t *testing.T) {
	k := &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.updateProjectSearch(p, searchQuery{text: "needle"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	h.app.closeProject()
	awaitDocumentState(t, h, func() bool { return h.app.project == nil })
	h.app.wait()
	if got := k.invalidations.Load(); got != 2 {
		t.Fatalf("index invalidations = %d, want search and cleanup", got)
	}
}

func TestProjectSearchReusesIndexUntilRefresh(t *testing.T) {
	k := &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.updateProjectSearch(p, searchQuery{text: "first"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	if !p.search.watchAvailable {
		t.Skip("recursive filesystem notifications are unavailable")
	}
	h.app.updateProjectSearch(p, searchQuery{text: "second"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	if got := k.invalidations.Load(); got != 1 {
		t.Fatalf("invalidations after two queries = %d, want 1", got)
	}
	h.app.refreshProjectSearch(p)
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	if got := k.invalidations.Load(); got != 2 {
		t.Fatalf("invalidations after explicit refresh = %d, want 2", got)
	}
}

func TestProjectSearchFallsBackWhenWatchCannotStart(t *testing.T) {
	k := &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	slot := &documentWatch{}
	replaceSearchWatchForTest(p, slot)
	p.search.watchAttached = true
	slot.finish(nil, errors.New("watch unavailable"))
	h.app.drainProjectSearchWatch(p, slot)
	if h.app.notice != i18n.Shared(h.app.language(), "desktop.search.watchUnavailable") {
		t.Fatal("watch failure was not reported")
	}
	for _, query := range []string{"first", "second"} {
		h.app.updateProjectSearch(p, searchQuery{text: query})
		awaitDocumentState(t, h, func() bool { return !p.search.loading })
	}
	if got := k.invalidations.Load(); got != 2 {
		t.Fatalf("fallback invalidations = %d, want 2", got)
	}
}

type lostSearchWatch struct{ closed bool }

func (*lostSearchWatch) Changes([]string) app.DirectoryChanges {
	return app.DirectoryChanges{Resync: true}
}
func (w *lostSearchWatch) Close() { w.closed = true }

func TestProjectSearchReopensWatchAfterLostEvents(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	old := &lostSearchWatch{}
	slot := &documentWatch{}
	slot.finish(old, nil)
	replaceSearchWatchForTest(p, slot)
	h.app.drainProjectSearchWatch(p, slot)
	if !old.closed || p.search.watch == nil || p.search.watch == slot || !p.search.fullResync {
		t.Fatal("lost events did not reopen the watch and invalidate the index")
	}
	awaitDocumentState(t, h, func() bool { return p.search.watchReady })
}

type batchSearchWatch struct{ names []string }

func (w *batchSearchWatch) Changes([]string) app.DirectoryChanges {
	return app.DirectoryChanges{Names: w.names}
}
func (*batchSearchWatch) Close() {}

type batchSearchKernel struct {
	*cleanupSearchKernel
	filtered, updated atomic.Int32
}

func (k *batchSearchKernel) FilterWorkspaceChanges(_ context.Context, paths []string) ([]string, error) {
	k.filtered.Store(int32(len(paths)))
	return []string{"source.go"}, nil
}
func (k *batchSearchKernel) UpdateWorkspaceSearch(_ context.Context, _ string, paths []string) error {
	k.updated.Store(int32(len(paths)))
	return nil
}

func TestProjectSearchFiltersEventsBeforeChoosingFullRebuild(t *testing.T) {
	k := &batchSearchKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	slot := &documentWatch{}
	slot.finish(&batchSearchWatch{names: make([]string, searchUpdateLimit+1)}, nil)
	slot.state() // A previously installed watch, not a new registration.
	replaceSearchWatchForTest(p, slot)
	p.search.watchReady, p.search.watchAvailable = true, true
	p.search.want = searchQuery{text: "needle"}
	h.app.drainProjectSearchWatch(p, slot)
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	if k.filtered.Load() != searchUpdateLimit+1 || k.updated.Load() != 1 || k.invalidations.Load() != 0 {
		t.Fatalf("filter=%d update=%d rebuild=%d", k.filtered.Load(), k.updated.Load(), k.invalidations.Load())
	}
}

type interruptedUpdateKernel struct {
	*batchSearchKernel
	started chan struct{}
}

func (k *interruptedUpdateKernel) UpdateWorkspaceSearch(ctx context.Context, _ string, _ []string) error {
	close(k.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestProjectSearchRebuildsAfterInterruptedIndexUpdate(t *testing.T) {
	k := &interruptedUpdateKernel{batchSearchKernel: &batchSearchKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}}, started: make(chan struct{})}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	slot := &documentWatch{}
	slot.finish(&batchSearchWatch{names: []string{"source.go"}}, nil)
	slot.state()
	replaceSearchWatchForTest(p, slot)
	p.search.watchReady, p.search.watchAvailable = true, true
	p.search.want = searchQuery{text: "first"}
	h.app.drainProjectSearchWatch(p, slot)
	select {
	case <-k.started:
	case <-time.After(5 * time.Second):
		t.Fatal("incremental update did not start")
	}
	h.app.updateProjectSearch(p, searchQuery{text: "second"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading })
	if k.invalidations.Load() != 1 {
		t.Fatalf("invalidations after interrupted update = %d, want 1", k.invalidations.Load())
	}
}

type closeSearchKernel struct {
	*cleanupSearchKernel
	started chan struct{}
	release chan struct{}
}

func (k *closeSearchKernel) SearchWorkspace(context.Context, core.WorkspaceSearchRequest) ([]core.WorkspaceSearchMatch, error) {
	close(k.started)
	<-k.release
	return nil, nil
}

func TestProjectSearchCloseWaitsForInflightIndexBeforeCleanup(t *testing.T) {
	k := &closeSearchKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}, started: make(chan struct{}), release: make(chan struct{})}
	h := newHarness(t, k)
	h.app.searchView.delay = 0
	h.open(t.TempDir())
	defer func() {
		select {
		case <-k.release:
		default:
			close(k.release)
		}
	}()
	p := h.app.project
	h.app.updateProjectSearch(p, searchQuery{text: "needle"})
	awaitDocumentState(t, h, func() bool { return p.search.running })
	select {
	case <-k.started:
	case <-time.After(5 * time.Second):
		t.Fatal("search did not start")
	}
	h.app.closeProject()
	if got := k.invalidations.Load(); got != 1 {
		t.Fatalf("cleanup ran before in-flight search ended: %d", got)
	}
	close(k.release)
	h.app.wait()
	if got := k.invalidations.Load(); got != 2 {
		t.Fatalf("cleanup invalidations = %d, want 2", got)
	}
}

func TestProjectSearchVirtualizesAndDisclosesResultLimit(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.click(center(h.button(itemFind)))
	p := h.app.project
	h.app.searchView.query.SetText("sample")
	p.search.want = searchQuery{text: "sample"}
	p.search.matches = make([]core.WorkspaceSearchMatch, searchMaxResults)
	for i := range p.search.matches {
		p.search.matches[i] = core.WorkspaceSearchMatch{Path: fmt.Sprintf("file-%03d.txt", i), Preview: "sample"}
	}
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	countRows := func() int {
		n := 0
		for _, hit := range h.driver.Snapshot().Hits {
			if strings.HasPrefix(hit.Label, "file-") && !hit.IsLabel {
				n++
			}
		}
		return n
	}
	if got := countRows(); got < 1 || got > 20 {
		t.Fatalf("visible rows = %d", got)
	}
	at := center(h.pageHit("file-000.txt").Bounds)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: at.X, Y: at.Y, DeltaY: 20000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if got := countRows(); got > 20 {
		t.Fatalf("scrolled rows = %d", got)
	}
	want := i18n.Shared(h.app.language(), "desktop.search.first200")
	found := false
	for _, label := range h.driver.Snapshot().Labels {
		if len(label.Value) > 8 && strings.HasPrefix(want, label.Value) {
			found = true
		}
	}
	if !found {
		t.Fatal("result limit is not disclosed")
	}
}

func TestProjectSearchRejectsPathsOutsideWorkspace(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	for _, path := range []string{"", "../outside.txt", filepath.Join(filepath.Dir(root), "outside.txt")} {
		h.app.openSearchResult(p, core.WorkspaceSearchMatch{Path: path})
	}
	if len(p.docs.list) != 0 || len(p.docs.opening) != 0 {
		t.Fatal("invalid result opened outside the workspace")
	}
}

// clickClear presses the nth clear button of the Find in Files fields, from the top.
func (h *harness) clickClear(n int) {
	h.t.Helper()
	name := i18n.Shared(h.app.language(), "native.clearSearch")
	var found []gfx.Hit
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == name && !hit.IsLabel && !hit.ID.IsZero() {
			found = append(found, hit)
		}
	}
	sort.Slice(found, func(i, j int) bool { return found[i].Bounds.Y < found[j].Bounds.Y })
	if n >= len(found) {
		h.t.Fatalf("clear button %d not shown, have %d", n, len(found))
	}
	h.click(center(found[n].Bounds))
}

// A Find in Files result's context menu copies the file's path relative to the project and
// opens the match, as Search Everywhere's results do.
func TestProjectSearchResultMenuCopiesThePathAndOpens(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	path := filepath.Join(root, "example.go")
	if err := os.WriteFile(path, []byte("first\nsecond needle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.click(center(h.button(itemFind)))
	if err := h.driver.Click(center(h.hit(searchQueryID)).X, center(h.hit(searchQueryID)).Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("needle"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 1 })
	h.settle()
	label := searchMatchLabel(p.search.matches[0])

	h.rightClickNamed(label)
	h.click(center(h.popupHit(h.shared("desktop.files.copyRelativePath"))))
	if got := h.driver.Clipboard(); got != "example.go" {
		t.Fatalf("the clipboard holds %q, want the path relative to the project", got)
	}
	h.rightClickNamed(label)
	h.click(center(h.popupHit(h.shared("desktop.files.open"))))
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(path) != nil })
}
