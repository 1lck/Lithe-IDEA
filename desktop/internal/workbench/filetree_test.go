package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

type delayedTreeKernel struct {
	*testKernel
	armed   atomic.Bool
	calls   atomic.Int32
	started [2]chan struct{}
	release [2]chan struct{}
}

type countedTreeFilterKernel struct {
	*testKernel
	listings atomic.Int32
	filtered chan struct{}
}

type blockedTreeFilterKernel struct {
	*testKernel
	armed            atomic.Bool
	started, release chan struct{}
}

type failingTreeListingKernel struct {
	*testKernel
	armed atomic.Bool
}

func (k *failingTreeListingKernel) ListDirectories(ctx context.Context, root string, paths []string) ([]core.DirectoryListing, error) {
	if k.armed.Load() {
		return nil, errors.New("directory listing failed")
	}
	return k.Client.ListDirectories(ctx, root, paths)
}

type treeRecordingLog struct {
	logwindow.Source
	mu     sync.Mutex
	events []core.LogEvent
}

func (l *treeRecordingLog) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, core.LogEvent{Level: level, Event: event, Fields: fields})
}

func TestProjectTreeBatchFailureLogsOnce(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a", "b"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	kernel := &failingTreeListingKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	kernel.armed.Store(true)
	h.app.listTree(p, "a", "b")
	awaitDocumentState(t, h, func() bool { return !p.tree.reading && !p.tree.find("a").loading && !p.tree.find("b").loading })
	logger.mu.Lock()
	defer logger.mu.Unlock()
	if len(logger.events) != 1 || logger.events[0].Event != operationFailedEvent || logger.events[0].Fields["operation"] != "project_tree_list" {
		t.Fatalf("batch failure logs = %+v", logger.events)
	}
}

func (k *blockedTreeFilterKernel) FilterWorkspaceChanges(ctx context.Context, paths []string) ([]string, error) {
	if k.armed.Load() {
		close(k.started)
		select {
		case <-k.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return k.Client.FilterWorkspaceChanges(ctx, paths)
}

func (k *countedTreeFilterKernel) ListDirectories(ctx context.Context, root string, paths []string) ([]core.DirectoryListing, error) {
	k.listings.Add(1)
	return k.Client.ListDirectories(ctx, root, paths)
}

func (k *countedTreeFilterKernel) FilterWorkspaceChanges(ctx context.Context, paths []string) ([]string, error) {
	filtered, err := k.Client.FilterWorkspaceChanges(ctx, paths)
	select {
	case k.filtered <- struct{}{}:
	default:
	}
	return filtered, err
}

func TestProjectTreeUsesCoreToFilterHiddenEvents(t *testing.T) {
	k := &countedTreeFilterKernel{testKernel: &testKernel{Client: core.NewClient()}, filtered: make(chan struct{}, 1)}
	h := newHarness(t, k)
	h.open(t.TempDir())
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && !p.tree.reading })
	h.app.closeTree(p)
	p.tree.recursiveWatch = true
	p.search.watch = &documentWatch{}
	before := k.listings.Load()
	h.app.applyTreeRecursiveWatch(p, false, true, nil, app.DirectoryChanges{Names: []string{"node_modules/tool/generated.js"}})
	select {
	case <-k.filtered:
	case <-time.After(8 * time.Second):
		t.Fatal("Core did not filter the native event")
	}
	h.app.wait()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if got := k.listings.Load(); got != before {
		t.Fatalf("hidden event caused a directory read: %d to %d", before, got)
	}
}

func TestProjectTreeFindsNewParentFromNestedEvent(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && !p.tree.reading })
	h.app.closeTree(p)
	p.tree.recursiveWatch = true
	p.search.watch = &documentWatch{}
	if err := os.Mkdir(filepath.Join(root, "newdir"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "newdir", "child.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	// Model an OS batch that names only the child, not its newly created parent.
	h.app.applyTreeRecursiveWatch(p, false, true, nil, app.DirectoryChanges{Names: []string{"newdir/child.txt"}})
	awaitDocumentState(t, h, func() bool { return p.tree.find("newdir") != nil })
}

func TestProjectTreeWindowsEventMatchesDirectoryCase(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows native names are case-insensitive")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "src")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "old.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("src")
	h.app.toggleFolder(p, folder)
	awaitDocumentState(t, h, func() bool { return folder.listed && !p.tree.reading })
	h.app.closeTree(p)
	p.tree.recursiveWatch = true
	p.search.watch = &documentWatch{}
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.applyTreeRecursiveWatch(p, false, true, nil, app.DirectoryChanges{Names: []string{"SRC/new.txt"}})
	awaitDocumentState(t, h, func() bool { return p.tree.find("src/new.txt") != nil })
}

func TestProjectTreeEventOverflowRescansWhileFilterIsBlocked(t *testing.T) {
	k := &blockedTreeFilterKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{}), release: make(chan struct{})}
	h := newHarness(t, k)
	var released sync.Once
	t.Cleanup(func() { released.Do(func() { close(k.release) }) })
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && !p.tree.reading })
	h.app.closeTree(p)
	p.tree.recursiveWatch = true
	p.search.watch = &documentWatch{}
	k.armed.Store(true)
	h.app.applyTreeRecursiveWatch(p, false, true, nil, app.DirectoryChanges{Names: []string{"stale.txt"}})
	select {
	case <-k.started:
	case <-time.After(8 * time.Second):
		t.Fatal("event filter did not start")
	}
	if err := os.WriteFile(filepath.Join(root, "latest.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.applyTreeRecursiveWatch(p, false, true, nil, app.DirectoryChanges{Names: make([]string, searchEventLimit+1)})
	awaitDocumentState(t, h, func() bool { return p.tree.find("latest.txt") != nil })
	if len(p.tree.eventPending) != 0 {
		t.Fatal("overflow retained an unbounded event batch")
	}
	released.Do(func() { close(k.release) })
	awaitDocumentState(t, h, func() bool { return !p.tree.eventFiltering })
	if p.tree.find("latest.txt") == nil {
		t.Fatal("a stale filtered result replaced the rescan")
	}
}

func TestProjectTreeReattachesToExistingSearchWatch(t *testing.T) {
	if !treeUsesRecursiveWatch() {
		t.Skip("shared recursive stream is used on macOS and Windows")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "src")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "before.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && p.search.watchReady })
	folder := p.tree.find("src")
	h.app.toggleFolder(p, folder)
	awaitDocumentState(t, h, func() bool { return folder.listed && !p.tree.reading })
	// Simulate another search retaining the stream while the tree is detached.
	p.search.watchAttached = true
	h.app.closeTree(p)
	replaceSearchWatchForTest(p, &documentWatch{})
	p.search.watchReady, p.search.watchAvailable = true, true
	if err := os.WriteFile(filepath.Join(dir, "during.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.listTree(p, "")
	awaitDocumentState(t, h, func() bool { return p.tree.find("src/during.txt") != nil })
	if !folder.expanded {
		t.Fatal("reattaching lost the expanded directory")
	}
}

func (k *delayedTreeKernel) ListDirectories(ctx context.Context, root string, paths []string) ([]core.DirectoryListing, error) {
	listings, err := k.Client.ListDirectories(ctx, root, paths)
	if !k.armed.Load() {
		return listings, err
	}
	index := int(k.calls.Add(1)) - 1
	if index >= len(k.started) {
		return listings, err
	}
	close(k.started[index])
	select {
	case <-k.release[index]:
		return listings, err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func TestProjectTreeDiscardsListingSupersededByChange(t *testing.T) {
	kernel := &delayedTreeKernel{testKernel: &testKernel{Client: core.NewClient()}}
	var released [2]sync.Once
	for i := range kernel.started {
		kernel.started[i], kernel.release[i] = make(chan struct{}), make(chan struct{})
	}
	h := newHarness(t, kernel)
	t.Cleanup(func() {
		for i := range kernel.release {
			i := i
			released[i].Do(func() { close(kernel.release[i]) })
		}
	})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed && !p.tree.reading })
	// Suppress unrelated native notifications so the test owns the event order.
	h.app.closeTree(p)
	if treeUsesRecursiveWatch() {
		p.tree.recursiveWatch = true
		p.search.watch = &documentWatch{}
	} else {
		p.tree.watches = map[string]*documentWatch{"": {}}
	}
	if err := os.WriteFile(filepath.Join(root, "first.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	kernel.armed.Store(true)
	h.app.listTree(p, "")
	wait := func(signal <-chan struct{}) {
		t.Helper()
		timer := time.NewTimer(8 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-signal:
				return
			case <-h.driver.Wakes():
				if err := h.driver.Pump(); err != nil {
					t.Fatal(err)
				}
			case <-timer.C:
				t.Fatal("directory read did not reach its synchronization point")
			}
		}
	}
	wait(kernel.started[0])
	if err := os.WriteFile(filepath.Join(root, "second.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.listTree(p, "")
	released[0].Do(func() { close(kernel.release[0]) })
	wait(kernel.started[1])
	if p.tree.find("first.txt") != nil {
		t.Fatal("a superseded listing was published before the replacement completed")
	}
	released[1].Do(func() { close(kernel.release[1]) })
	awaitDocumentState(t, h, func() bool { return p.tree.find("second.txt") != nil })
	if p.tree.find("first.txt") == nil {
		t.Fatal("replacement listing omitted the first file")
	}
}

func TestProjectTreeRefreshPreservesSurvivingState(t *testing.T) {
	tree := fileTree{root: &treeNode{dir: true, expanded: true}}
	tree.replaceChildren(tree.root, []core.WorkspaceNode{{Path: "src", Name: "src", IsDirectory: true}})
	folder := tree.root.children[0]
	folder.expanded, folder.listed = true, true
	tree.replaceChildren(folder, []core.WorkspaceNode{{Path: "src/a.go", Name: "a.go"}})
	file := folder.children[0]
	tree.selected = file
	tree.replaceChildren(tree.root, []core.WorkspaceNode{
		{Path: "src", Name: "src", IsDirectory: true},
		{Path: "new", Name: "new"},
	})
	if tree.root.children[0] != folder || !folder.expanded || !folder.listed || tree.selected != file {
		t.Fatal("refresh lost a surviving folder or its selected descendant")
	}
	tree.replaceChildren(folder, nil)
	if tree.selected != folder || tree.focus != treeRows.At(folder.id) {
		t.Fatal("removing the selected file did not move selection to its parent")
	}
	tree.replaceChildren(tree.root, []core.WorkspaceNode{{Path: "src", Name: "src"}})
	if tree.root.children[0] == folder || tree.selected != nil {
		t.Fatal("replacing a directory with a file retained the old subtree")
	}
}

func TestProjectTreePathIndexDropsReplacedSubtree(t *testing.T) {
	tree := fileTree{root: &treeNode{dir: true, expanded: true}}
	tree.replaceChildren(tree.root, []core.WorkspaceNode{{Path: "src", Name: "src", IsDirectory: true}})
	folder := tree.root.children[0]
	tree.replaceChildren(folder, []core.WorkspaceNode{{Path: "src/main.go", Name: "main.go"}})
	if tree.find("src/main.go") == nil {
		t.Fatal("loaded child was not indexed")
	}
	tree.replaceChildren(tree.root, []core.WorkspaceNode{{Path: "src", Name: "src"}})
	if tree.find("src/main.go") != nil || tree.find("src") == nil || tree.find("src").dir {
		t.Fatal("replacing a directory left its old subtree in the path index")
	}
}

func TestProjectTreeFollowsExternalDirectoryChanges(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(root, "src", "old.go")
	if err := os.WriteFile(old, []byte("package old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("src")
	h.app.toggleFolder(p, folder)
	awaitDocumentState(t, h, func() bool { return folder.listed })
	selected := p.tree.find("src/old.go")
	p.tree.selected = selected
	if err := os.WriteFile(filepath.Join(root, "new.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.find("new.txt") != nil })
	if p.tree.find("src") != folder || !folder.expanded || p.tree.selected != selected {
		t.Fatal("root change lost an expanded folder or its selected child")
	}
	if err := os.Remove(old); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.find("src/old.go") == nil })
	if p.tree.selected != folder {
		t.Fatal("removing the selected file did not select its parent")
	}
	if err := os.WriteFile(filepath.Join(root, "src", "restored.go"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.find("src/restored.go") != nil })
	if !folder.expanded {
		t.Fatal("a previously expanded directory lost its expansion after becoming empty")
	}
	var watches []*documentWatch
	if treeUsesRecursiveWatch() {
		watches = []*documentWatch{p.search.watch}
	} else {
		watches = []*documentWatch{p.tree.watches[""], p.tree.watches["src"]}
	}
	for _, watch := range watches {
		if watch == nil {
			t.Fatal("expected active project watches")
		}
	}
	h.app.closeProject()
	awaitDocumentState(t, h, func() bool { return h.app.project == nil })
	for _, watch := range watches {
		watch.mu.Lock()
		closed := watch.closed
		watch.mu.Unlock()
		if !closed {
			t.Fatal("closing the project retained a directory watch")
		}
	}
}

func TestProjectTreeEmptyFolderBecomesExpandable(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "empty"), 0o700); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("empty")
	if folder == nil || !folder.empty {
		t.Fatal("Core did not report the initially empty directory")
	}
	if err := os.WriteFile(filepath.Join(root, "empty", "created.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !folder.empty })
	h.app.toggleFolder(p, folder)
	awaitDocumentState(t, h, func() bool { return p.tree.find("empty/created.txt") != nil })
}

func TestProjectTreeManyEmptyDirectoriesShareRecursiveWatch(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		t.Skip("recursive native stream is used on macOS and Windows")
	}
	root := t.TempDir()
	for i := 0; i < 140; i++ {
		if err := os.Mkdir(filepath.Join(root, fmt.Sprintf("folder-%03d", i)), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("folder-139")
	if folder == nil || !folder.empty {
		t.Fatal("expected an empty directory")
	}
	if err := os.WriteFile(filepath.Join(root, "folder-139", "new.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !folder.empty })
	if p.search.watch == nil || len(p.tree.watches) != 0 {
		t.Fatalf("recursive watch was not shared: search=%v per-directory=%d", p.search.watch != nil, len(p.tree.watches))
	}
}

func TestProjectTreeCollapsedDirectoryBecomesEmpty(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		t.Skip("recursive native stream is used on macOS and Windows")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "collapsed")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "only.txt")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("collapsed")
	if folder == nil || folder.empty || folder.expanded {
		t.Fatal("expected a collapsed nonempty directory")
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return folder.empty })
}

func TestProjectTreeExternalInsertKeepsViewportAnchor(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 80; i++ {
		name := fmt.Sprintf("file-%03d.txt", i)
		if err := os.WriteFile(filepath.Join(root, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	scroll := h.app.view.ScrollState(treeListID)
	scroll.ScrollTo(4 + 35*rowHeight + 7)
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	before := scroll.Offset
	anchor := p.tree.rows[35]
	if err := os.WriteFile(filepath.Join(root, "aaa.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.find("aaa.txt") != nil })
	if p.tree.rows[36] != anchor || scroll.Offset != before+rowHeight {
		t.Fatalf("viewport anchor moved: offset %v to %v", before, scroll.Offset)
	}
}

func TestProjectTreeCanRetryAfterRootDisappears(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "workspace")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "first.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.find("first.txt") != nil })
	if err := os.RemoveAll(root); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.failed != "" })
	if len(p.tree.watches) != 0 {
		t.Fatal("an unavailable project root retained directory watches")
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "restored.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	point := center(h.hit(treeRetryID))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return p.tree.failed == "" && p.tree.find("restored.txt") != nil })
}

func TestProjectTreeWatchLimitReportsDegradedUpdates(t *testing.T) {
	if treeUsesRecursiveWatch() {
		t.Skip("the recursive stream does not use per-directory registrations")
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	h.app.closeTree(p)
	p.tree.watches = make(map[string]*documentWatch, treeWatchLimit)
	for i := 0; i < treeWatchLimit; i++ {
		p.tree.watches[fmt.Sprintf("fake-%d", i)] = &documentWatch{}
	}
	folder := &treeNode{path: "extra", dir: true, empty: true}
	h.app.watchTreeNode(p, folder)
	if len(p.tree.watches) != treeWatchLimit || p.tree.watches["extra"] != nil {
		t.Fatal("watch limit did not bound registrations")
	}
	if h.app.notice != i18n.Shared(h.app.language(), "desktop.project.watchUnavailable") {
		t.Fatalf("missing degraded-monitoring notice: %q", h.app.notice)
	}
}

func TestProjectTreeFolderSelectionAndDisclosure(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	folder := p.tree.find("src")
	if folder == nil || !folder.dir {
		t.Fatal("project folder is missing")
	}
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	row := h.hit(treeRows.At(folder.id))
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == treeArrows.At(folder.id) && hit.Label != "展开目录 src" {
			t.Fatalf("disclosure accessibility label = %q", hit.Label)
		}
	}
	name := ui.Point{X: row.X + row.Width - 20, Y: row.Y + row.Height/2}
	if err := h.driver.Click(name.X, name.Y); err != nil {
		t.Fatal(err)
	}
	if p.tree.selected != folder || folder.expanded {
		t.Fatalf("single click selection=%v expanded=%v", p.tree.selected, folder.expanded)
	}
	if err := h.driver.PressCount(name.X, name.Y, ui.PointerButtonPrimary, 2); err != nil {
		t.Fatal(err)
	}
	if !folder.expanded {
		t.Fatal("second press did not expand folder")
	}
	if err := h.driver.ReleaseCount(name.X, name.Y, ui.PointerButtonPrimary, 2); err != nil {
		t.Fatal(err)
	}
	if !folder.expanded {
		t.Fatal("second release toggled the folder again")
	}
	awaitDocumentState(t, h, func() bool { return folder.listed })
	arrow := center(h.hit(treeArrows.At(folder.id)))
	if err := h.driver.Click(arrow.X, arrow.Y); err != nil {
		t.Fatal(err)
	}
	if folder.expanded || p.tree.selected != folder {
		t.Fatal("disclosure did not collapse the selected folder")
	}
	if err := h.driver.Key(ui.KeyRight, 0); err != nil {
		t.Fatal(err)
	}
	if !folder.expanded {
		t.Fatal("right arrow did not expand folder")
	}
}

func TestProjectTreeRootIsVisibleAndCollapsible(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "README.md"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if len(p.tree.rows) != 2 || p.tree.rows[0] != p.tree.root || p.tree.rows[1].depth != 1 {
		t.Fatalf("expected root followed by its child: %#v", p.tree.rows)
	}
	styledRoot := false
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == p.tree.root.name && label.Bounds.Y >= p.tree.areaRect.Y && label.Bounds.Y < p.tree.areaRect.Y+p.tree.areaRect.Height && label.FontSize == 13 && label.Weight == ui.WeightSemibold && label.Color == ui.RGB24(0xD1D3D9) {
			styledRoot = true
		}
	}
	if !styledRoot {
		t.Fatal("root label is missing the native tree typography or color")
	}
	_ = h.hit(treeRows.At(p.tree.root.id))
	arrow := center(h.hit(treeArrows.At(p.tree.root.id)))
	if err := h.driver.Click(arrow.X, arrow.Y); err != nil {
		t.Fatal(err)
	}
	if p.tree.root.expanded || len(p.tree.rows) != 1 || p.tree.selected != p.tree.root {
		t.Fatal("root disclosure did not collapse and select the root")
	}
	row := h.hit(treeRows.At(p.tree.root.id))
	painted := false
	for _, primitive := range h.driver.Snapshot().Primitives {
		if primitive.Bounds == row && primitive.Radius == 4 && primitive.Color == ui.RGB24(0x2A4371) {
			painted = true
		}
	}
	if !painted {
		t.Fatal("focused root selection is missing the native rounded highlight")
	}
	if err := h.driver.Key(ui.KeyRight, 0); err != nil {
		t.Fatal(err)
	}
	if !p.tree.root.expanded || len(p.tree.rows) != 2 {
		t.Fatal("right arrow did not reopen the root")
	}
}

func TestProjectTreeEmptyRootRemainsVisible(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if len(p.tree.rows) != 1 || p.tree.rows[0] != p.tree.root || !p.tree.root.empty {
		t.Fatal("empty project must still display its root")
	}
	_ = h.hit(treeRows.At(p.tree.root.id))
}

func TestProjectTreeLightThemeUsesNativeLabelColor(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.settings.Theme = themeLight
	h.open(t.TempDir())
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Resize(1280, 720); err != nil {
		t.Fatal(err)
	}
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == p.tree.root.name && label.Bounds.Y >= p.tree.areaRect.Y && label.Bounds.Y < p.tree.areaRect.Y+p.tree.areaRect.Height && label.Color == ui.RGB24(0x000000) {
			return
		}
	}
	t.Fatal("light tree root did not use the native text color")
}

func TestProjectTreeLongRootCanScrollToNameEnd(t *testing.T) {
	root := filepath.Join(t.TempDir(), strings.Repeat("m", 180))
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	var right float32
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == p.tree.root.name && label.Bounds.Y >= p.tree.areaRect.Y && label.Bounds.Y < p.tree.areaRect.Y+p.tree.areaRect.Height {
			right = max(right, label.Bounds.X+label.Bounds.Width-p.tree.areaRect.X)
		}
	}
	if right <= p.tree.viewport || p.tree.width < right {
		t.Fatalf("long root end=%v width=%v viewport=%v", right, p.tree.width, p.tree.viewport)
	}
	area := p.tree.areaRect
	if err := h.driver.Scroll(ui.ScrollEvent{X: area.X + 20, Y: area.Y + 20, DeltaX: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if p.tree.scrollX <= 0 || right-p.tree.scrollX > p.tree.viewport {
		t.Fatal("horizontal scroll cannot expose the end of the root name")
	}
}

func TestProjectTreeKeyboardKeepsSelectionVisible(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 40; i++ {
		name := fmt.Sprintf("folder-%02d", i)
		if i == 39 {
			name += strings.Repeat("x", 160)
		}
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	awaitDocumentState(t, h, func() bool { return p.tree.root != nil && p.tree.root.listed })
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	visibleHits := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if _, ok := hit.ID.In(treeRows); ok {
			visibleHits++
		}
	}
	if visibleHits == 0 || visibleHits >= len(p.tree.rows) {
		t.Fatalf("viewport declared %d of %d rows", visibleHits, len(p.tree.rows))
	}
	if p.tree.width <= p.tree.viewport {
		t.Fatal("offscreen long filename did not extend the horizontal scroll range")
	}
	first := p.tree.root.children[0]
	point := center(h.hit(treeRows.At(first.id)))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	if !first.empty {
		t.Fatal("empty directory was not identified by Core")
	}
	if err := h.driver.Key(ui.KeyRight, 0); err != nil {
		t.Fatal(err)
	}
	if first.expanded {
		t.Fatal("right arrow expanded an empty directory")
	}
	for i := 0; i < 35; i++ {
		if err := h.driver.Key(ui.KeyDown, 0); err != nil {
			t.Fatal(err)
		}
	}
	if p.tree.selected != p.tree.root.children[35] || h.app.view.ScrollState(treeListID).Offset <= 0 {
		t.Fatalf("selected=%v offset=%v", p.tree.selected, h.app.view.ScrollState(treeListID).Offset)
	}
	_ = h.hit(treeRows.At(p.tree.selected.id))
	if err := h.driver.Key(ui.KeyUp, 0); err != nil {
		t.Fatal(err)
	}
	if p.tree.selected != p.tree.root.children[34] {
		t.Fatal("keyboard focus was lost after scrolling")
	}
	area := p.tree.areaRect
	if err := h.driver.Scroll(ui.ScrollEvent{X: area.X + 20, Y: area.Y + 20, DeltaX: 200, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if p.tree.scrollX <= 0 {
		t.Fatal("long name could not be reached by horizontal scrolling")
	}
}
