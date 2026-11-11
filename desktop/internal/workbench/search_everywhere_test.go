package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func TestEverywhereFindsPagesAndOpensSelectedFile(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.everywhereView.delay = 0
	root := t.TempDir()
	for i := 0; i < 60; i++ {
		name := filepath.Join(root, fmt.Sprintf("file-%02d.txt", i))
		if err := os.WriteFile(name, []byte("content token\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	h.click(center(h.button(itemTitleSearch)))
	if focused := h.driver.Snapshot().Focused; focused != everywhereQueryID {
		t.Fatalf("opening global search focused %v instead of its query", focused)
	}
	at := center(h.hit(everywhereQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("file-"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == everywherePageSize })
	if p.everywhere.cursor == nil {
		t.Fatal("first page did not offer a continuation")
	}
	// The preview shows the selected file's name too; a row below the first is only in the list.
	area := center(h.pageHit("file-05.txt").Bounds)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: area.X, Y: area.Y, DeltaY: 20000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	// Scrolling to the end of the list loads the next page; there is no button for it.
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == 60 })
	if p.everywhere.cursor != nil {
		t.Fatal("last page unexpectedly has a continuation")
	}
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(filepath.Join(root, "file-00.txt")) != nil })
	if h.app.everywhereView.open {
		t.Fatal("opening a result did not close the search")
	}
}

func TestEverywhereOpensWithFileSearchShortcut(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	handled, err := h.driver.ShortcutChord(primaryModifier()|gfx.ModifierShift, 'o')
	if err != nil || !handled {
		t.Fatalf("shortcut: handled=%v error=%v", handled, err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if !h.app.everywhereView.open || h.driver.Snapshot().Focused != everywhereQueryID {
		t.Fatal("shortcut did not open and focus global search")
	}
}

func TestEverywhereTextScopeFindsContentAndClosesWithEscape(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.everywhereView.delay = 0
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "note.txt"), []byte("first\nunique token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.click(center(h.button(itemTitleSearch)))
	h.clickShared("desktop.everywhere.text")
	if err := h.driver.Advance(time.Second / 30); err != nil {
		t.Fatal(err)
	}
	at := center(h.hit(everywhereQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("unique"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == 1 })
	match := p.everywhere.matches[0]
	if match.Kind != "content" || match.Line == nil || *match.Line != 2 {
		t.Fatalf("content result = %+v", match)
	}
	if !p.everywhere.watchAvailable {
		t.Skip("recursive filesystem notifications are unavailable")
	}
	if err := os.WriteFile(filepath.Join(root, "note.txt"), []byte("unique changed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool {
		return !p.everywhere.loading && len(p.everywhere.matches) == 1 && p.everywhere.matches[0].Line != nil && *p.everywhere.matches[0].Line == 1
	})
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.everywhereView.open {
		t.Fatal("Escape did not close global search")
	}
	if p.everywhere.watchAttached || (p.search.watch != nil && !p.tree.recursiveWatch) {
		t.Fatal("closing global search retained its filesystem watch")
	}
}

func TestEverywhereTracksNewAndRemovedFiles(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.everywhereView.delay = 0
	root := t.TempDir()
	h.open(root)
	h.click(center(h.button(itemTitleSearch)))
	at := center(h.hit(everywhereQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("needle"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.everywhere.watchReady && !p.everywhere.loading })
	if !p.everywhere.watchAvailable {
		t.Skip("recursive filesystem notifications are unavailable")
	}
	dir := filepath.Join(root, "nested")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "needle.txt"), []byte("sample"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool {
		return !p.everywhere.loading && len(p.everywhere.matches) == 1 && p.everywhere.matches[0].Path == "nested/needle.txt"
	})
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == 0 })
}

func TestSearchPanelsShareAndReleaseOneTreeWatch(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay, h.app.everywhereView.delay = 0, 0
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "needle.txt"), []byte("needle\n"), 0o600); err != nil {
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
	awaitDocumentState(t, h, func() bool { return p.search.watchReady && !p.search.loading })
	if !p.search.watchAvailable {
		t.Skip("recursive filesystem notifications are unavailable")
	}
	slot := p.search.watch
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("needle")
	h.app.updateEverywhere(p, "needle", 0)
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) > 0 })
	if p.search.watch != slot || !p.search.watchAttached || !p.everywhere.watchAttached {
		t.Fatal("search panels did not share their tree watch")
	}
	if err := os.WriteFile(filepath.Join(root, "needle-new.txt"), []byte("needle\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	containsNew := func(matches []core.WorkspaceSearchMatch) bool {
		for _, match := range matches {
			if match.Path == "needle-new.txt" {
				return true
			}
		}
		return false
	}
	awaitDocumentState(t, h, func() bool {
		return !p.search.loading && !p.everywhere.loading && containsNew(p.search.matches) && containsNew(p.everywhere.matches)
	})
	h.app.closeEverywhere(p)
	if p.search.watch != slot {
		t.Fatal("closing global search stopped the sidebar watch")
	}
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("needle")
	h.app.updateEverywhere(p, "needle", 0)
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) > 0 })
	h.app.cancelProjectSearch(p)
	if p.search.watch != slot {
		t.Fatal("closing sidebar search stopped the global watch")
	}
	h.app.closeEverywhere(p)
	if p.search.watchAttached || p.everywhere.watchAttached || (p.search.watch != nil && !p.tree.recursiveWatch) || (p.tree.recursiveWatch && p.search.watch != slot) {
		t.Fatal("closing the last search did not preserve only the tree's watch")
	}
}

func TestSearchPanelsBothResyncAfterLostWatchEvents(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	old := &lostSearchWatch{}
	slot := &documentWatch{}
	slot.finish(old, nil)
	replaceSearchWatchForTest(p, slot)
	p.search.watchAttached = true
	p.search.want = searchQuery{text: "needle"}
	p.everywhere.watchAttached, p.everywhere.query = true, "needle"
	h.app.drainProjectSearchWatch(p, slot)
	if !old.closed || p.search.watch == nil || p.search.watch == slot || p.search.watchReady || p.everywhere.watchReady {
		t.Fatal("both searches must wait for the replacement watch")
	}
	if !p.search.fullResync || !p.everywhere.fullResync || !p.search.loading || !p.everywhere.loading {
		t.Fatal("lost events did not schedule both searches for a full resync")
	}
	replacement := p.search.watch
	h.app.cancelProjectSearch(p)
	h.app.closeEverywhere(p)
	if p.search.watchAttached || p.everywhere.watchAttached || (p.search.watch != nil && !p.tree.recursiveWatch) || (p.tree.recursiveWatch && p.search.watch != replacement) {
		t.Fatal("replacement watch did not follow the remaining tree owner")
	}
}

type delayedEverywhereKernel struct {
	*testKernel
	started chan string
	release chan struct{}
}

func (*delayedEverywhereKernel) InvalidateWorkspaceSearch(context.Context, string) error { return nil }
func (k *delayedEverywhereKernel) SearchEverywherePage(_ context.Context, request core.EverywhereSearchRequest) (core.EverywhereSearchPage, error) {
	k.started <- request.Query
	if request.Query == "first" {
		<-k.release
	}
	return core.EverywhereSearchPage{Matches: []core.WorkspaceSearchMatch{{Kind: "file", Path: request.Query}}}, nil
}

func TestEverywhereSerializesQueriesAndDropsOldResults(t *testing.T) {
	k := &delayedEverywhereKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan string, 2), release: make(chan struct{})}
	h := newHarness(t, k)
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("first")
	h.app.updateEverywhere(p, "first", 0)
	defer func() {
		select {
		case <-k.release:
		default:
			close(k.release)
		}
	}()
	awaitDocumentState(t, h, func() bool { return p.everywhere.running })
	select {
	case got := <-k.started:
		if got != "first" {
			t.Fatal(got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("first search did not start")
	}
	h.app.everywhereView.query.SetText("second")
	h.app.updateEverywhere(p, "second", 0)
	select {
	case got := <-k.started:
		t.Fatalf("overlapping search: %s", got)
	default:
	}
	close(k.release)
	awaitDocumentState(t, h, func() bool {
		return !p.everywhere.loading && len(p.everywhere.matches) == 1 && p.everywhere.matches[0].Path == "second"
	})
}

func TestEverywhereLeavesCompositionKeysToInputMethod(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.click(center(h.button(itemTitleSearch)))
	at := center(h.hit(everywhereQueryID))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Compose("候选"); err != nil {
		t.Fatal(err)
	}
	p := h.app.project
	p.everywhere.matches = []core.WorkspaceSearchMatch{{Kind: "file", Path: "file.txt"}}
	for _, key := range []gfx.Key{gfx.KeyEnter, gfx.KeyEscape, gfx.KeyUp, gfx.KeyDown} {
		result := h.app.everywhereKey(p, gfx.KeyEvent{Target: everywhereQueryID, Key: key})
		if result.Handled || !h.app.everywhereView.open {
			t.Fatalf("composition key %v was intercepted", key)
		}
	}
}

func TestEverywhereRejectsRepeatedOrDuplicatePages(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	current, next := "cursor", "next"
	for _, returned := range []*string{&current, &next} {
		p.everywhere = everywhereSearch{generation: 1, cursor: &current, matches: []core.WorkspaceSearchMatch{{Kind: "file", Path: "file.txt"}}}
		h.app.finishEverywhere(p, 1, true, core.EverywhereSearchPage{Matches: []core.WorkspaceSearchMatch{{Kind: "file", Path: "file.txt"}}, NextCursor: returned}, nil, false)
		if !p.everywhere.failed || p.everywhere.cursor != nil || len(p.everywhere.matches) != 1 {
			t.Fatalf("non-advancing page accepted: %+v", p.everywhere)
		}
	}
}

type countedEverywhereKernel struct{ *cleanupSearchKernel }

func (*countedEverywhereKernel) SearchEverywherePage(context.Context, core.EverywhereSearchRequest) (core.EverywhereSearchPage, error) {
	return core.EverywhereSearchPage{}, nil
}

func TestEverywhereReusesIndexAcrossQueries(t *testing.T) {
	k := &countedEverywhereKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}}
	h := newHarness(t, k)
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	for _, query := range []string{"first", "second"} {
		h.app.everywhereView.query.SetText(query)
		h.app.updateEverywhere(p, query, 0)
		awaitDocumentState(t, h, func() bool { return !p.everywhere.loading })
		if !p.everywhere.watchAvailable {
			t.Skip("recursive filesystem notifications are unavailable")
		}
	}
	if got := k.invalidations.Load(); got != 1 {
		t.Fatalf("invalidations for two queries = %d, want 1", got)
	}
}

func TestEverywhereFallsBackWhenSharedWatchCannotStart(t *testing.T) {
	k := &countedEverywhereKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}}
	h := newHarness(t, k)
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	slot := &documentWatch{}
	replaceSearchWatchForTest(p, slot)
	p.everywhere.watchAttached = true
	slot.finish(nil, errors.New("watch unavailable"))
	h.app.drainProjectSearchWatch(p, slot)
	for _, query := range []string{"first", "second"} {
		h.app.everywhereView.query.SetText(query)
		h.app.updateEverywhere(p, query, 0)
		awaitDocumentState(t, h, func() bool { return !p.everywhere.loading })
	}
	if k.invalidations.Load() != 2 {
		t.Fatalf("fallback invalidations = %d, want 2", k.invalidations.Load())
	}
}

type interruptedEverywhereKernel struct {
	*countedEverywhereKernel
	started chan struct{}
}

func (*interruptedEverywhereKernel) FilterWorkspaceChanges(_ context.Context, paths []string) ([]string, error) {
	return paths, nil
}
func (k *interruptedEverywhereKernel) UpdateWorkspaceSearch(ctx context.Context, _ string, _ []string) error {
	close(k.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestEverywhereRebuildsAfterInterruptedIndexUpdate(t *testing.T) {
	k := &interruptedEverywhereKernel{countedEverywhereKernel: &countedEverywhereKernel{cleanupSearchKernel: &cleanupSearchKernel{testKernel: &testKernel{Client: core.NewClient()}}}, started: make(chan struct{})}
	h := newHarness(t, k)
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("first")
	slot := &documentWatch{}
	slot.finish(&batchSearchWatch{names: []string{"source.go"}}, nil)
	slot.state()
	replaceSearchWatchForTest(p, slot)
	p.search.watchReady, p.search.watchAvailable = true, true
	p.everywhere.watchAttached, p.everywhere.watchReady, p.everywhere.watchAvailable = true, true, true
	p.everywhere.query = "first"
	p.everywhere.request = core.EverywhereSearchRequest{Root: p.root, Query: "first", PageSize: 50, ResultKinds: []string{"file"}}
	h.app.drainProjectSearchWatch(p, slot)
	select {
	case <-k.started:
	case <-time.After(5 * time.Second):
		t.Fatal("incremental update did not start")
	}
	h.app.everywhereView.query.SetText("second")
	h.app.updateEverywhere(p, "second", 0)
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading })
	if got := k.invalidations.Load(); got != 1 {
		t.Fatalf("invalidations after cancelled update = %d, want 1", got)
	}
}

func TestEverywhereHangsFromTheTopAndClosesOnAPressOutside(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	if handled, err := h.driver.ShortcutChord(primaryModifier()|gfx.ModifierShift, 'o'); err != nil || !handled {
		t.Fatalf("shortcut: handled=%v error=%v", handled, err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	query := h.hit(everywhereQueryID)
	if query.Y < 84 || query.Y > 160 {
		t.Fatalf("the query field is at y=%v, want the panel at the top of the window", query.Y)
	}
	for _, primitive := range h.driver.Snapshot().Primitives {
		if primitive.Layer > 0 && primitive.Bounds.Width == float32(h.driver.Snapshot().Width) && primitive.Bounds.Height == float32(h.driver.Snapshot().Height) && primitive.Color.Alpha > 0 {
			t.Fatal("the search panel dims the window")
		}
	}
	h.click(gfx.Point{X: 4, Y: float32(h.driver.Snapshot().Height) - 4})
	if h.app.everywhereView.open {
		t.Fatal("a press outside did not close the search")
	}
}
