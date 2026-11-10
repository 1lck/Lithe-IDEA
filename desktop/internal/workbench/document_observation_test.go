package workbench

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

func TestExternalUnsupportedEncodingKeepsOpenBufferAndDiskBytes(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "document.txt")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	p := h.app.project
	doc := p.docs.byPath(path)
	if doc == nil {
		t.Fatal("document was not opened")
	}
	// Drive the external check explicitly, without a second OS watcher racing it.
	if watch := p.docs.watches[root]; watch != nil {
		watch.close()
		delete(p.docs.watches, root)
	}
	h.settle()
	awaitDocumentState(t, h, func() bool { return !doc.checking && !doc.checkPending })
	external := []byte{0xd6, 0xd0, 0xce, 0xc4}
	if err := os.WriteFile(path, external, 0o600); err != nil {
		t.Fatal(err)
	}
	doc.checkPending = true
	h.app.scheduleDocumentChecks(p)
	awaitDocumentState(t, h, func() bool { return doc.checkFailed && !doc.checking })
	if data, _ := doc.view.Text(); string(data) != "original" || !doc.checkFailed {
		t.Fatalf("unsupported external content replaced the open buffer: %q, failed %v", data, doc.checkFailed)
	}
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, external) {
		t.Fatalf("external content was changed: %x, error %v", data, err)
	}
}

// Wait on actual watcher and background completion signals rather than sleeping.
func awaitDocumentState(t *testing.T, h *harness, condition func() bool) {
	t.Helper()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for !condition() {
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-deadline.C:
			t.Fatal("document watcher did not deliver the expected state before the deadline")
		}
	}
}

func TestExternalDocumentChangesReloadCleanAndPreserveDirtyText(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "document.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	doc := h.app.project.docs.byPath(path)
	t.Cleanup(func() {
		defer func() { doc.conflicted = false; h.app.closeProject() }()
		for doc.view.Dirty() && doc.view.Undo() {
		}
		if doc.conflicted {
			if err := os.WriteFile(path, doc.view.SavedBytes(), 0o600); err != nil {
				t.Error(err)
				return
			}
			awaitDocumentState(t, h, func() bool { return !doc.conflicted })
		}
	})
	if err := os.WriteFile(path, []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { data, _ := doc.view.Text(); return string(data) == "external" })
	if doc.view.Dirty() {
		t.Fatal("external reload was marked dirty")
	}
	input := doc.view.TextInput(app.TextInputContext{ID: docViews.At(doc.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "local"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("other"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return doc.conflicted && !doc.conflictMissing })
	data, _ := doc.view.Text()
	if !strings.Contains(string(data), "local") || !doc.view.Dirty() {
		t.Fatalf("dirty edit lost: %q", data)
	}
}

func TestDeletedCleanDocumentIsNotDiscardedOnClose(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "removed.txt")
	if err := os.WriteFile(path, []byte("recoverable"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	t.Cleanup(func() {
		if h.app.project != p || p.docs.find(doc.id) != doc {
			return
		}
		defer func() { doc.conflicted = false; h.app.closeProject() }()
		if err := os.WriteFile(path, doc.view.SavedBytes(), 0o600); err != nil {
			t.Error(err)
			return
		}
		awaitDocumentState(t, h, func() bool { return !doc.conflicted })
	})
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return doc.conflicted && doc.conflictMissing })
	h.app.closeDocument(p, doc.id)
	if p.docs.byPath(path) == nil {
		t.Fatal("closing a deleted clean document discarded its only content")
	}
	h.app.closeProject()
	if h.app.project != p {
		t.Fatal("closing the project discarded a deleted document")
	}
	h.app.applyDocumentCheck(p, doc, doc.view.SavedSnapshot(), editorview.Prepare([]byte("replacement")), true, true, nil)
	if text, _ := doc.view.Text(); string(text) != "recoverable" || !doc.conflicted {
		t.Fatalf("a replacement silently resolved a deletion conflict: %q", text)
	}
}

type fakeDocumentWatch struct{ closed bool }

func (w *fakeDocumentWatch) Changes([]string) app.DirectoryChanges { return app.DirectoryChanges{} }
func (w *fakeDocumentWatch) Close()                                { w.closed = true }

func TestDocumentWatchClosesLateRegistration(t *testing.T) {
	slot := &documentWatch{}
	slot.close()
	late := &fakeDocumentWatch{}
	slot.finish(late, nil)
	if !late.closed {
		t.Fatal("watch registration completed after close and was not released")
	}
	if watch, _, _ := slot.state(); watch != nil {
		t.Fatal("closed slot retained a watch")
	}
}

func TestDocumentCheckRejectsStaleSavedBaseline(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "document.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	baseline := doc.view.SavedSnapshot()
	input := doc.view.TextInput(app.TextInputContext{ID: docViews.At(doc.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "saved"}); err != nil {
		t.Fatal(err)
	}
	_, saved := doc.view.Text()
	doc.view.MarkSaved(saved)
	h.app.applyDocumentCheck(p, doc, baseline, editorview.Prepare([]byte("stale")), true, true, nil)
	current, _ := doc.view.Text()
	if !doc.checkPending || !strings.Contains(string(current), "saved") {
		t.Fatalf("stale result was applied: %q", current)
	}
	h.app.closeProject()
}

func TestDocumentChecksAreBoundedAndDrainPending(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	for id := 1; id <= 6; id++ {
		v := editorview.New(editorview.Config{HitID: docViews.At(id), Content: editorview.Prepare([]byte("same"))})
		p.docs.list = append(p.docs.list, &document{id: id, path: filepath.Join(p.root, fmt.Sprintf("%d.txt", id)), view: v, checkPending: true})
	}
	started := make(chan struct{}, 6)
	release := make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	t.Cleanup(func() {
		for _, doc := range p.docs.list {
			doc.view.Close()
		}
		p.docs.list = nil
	})
	h.app.documentReader = func(string) ([]byte, error) {
		select {
		case started <- struct{}{}:
		default:
		}
		<-release
		return []byte("same"), nil
	}
	h.app.scheduleDocumentChecks(p)
	for range documentChecksInFlight {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatal("document check did not start")
		}
	}
	if p.docs.checking != documentChecksInFlight {
		t.Fatalf("in flight = %d", p.docs.checking)
	}
	select {
	case <-started:
		t.Fatal("more than four document checks started")
	default:
	}
	// Release all workers; completions schedule the pending documents on the window thread.
	close(release)
	released = true
	awaitDocumentState(t, h, func() bool {
		if p.docs.checking != 0 {
			return false
		}
		for _, doc := range p.docs.list {
			if doc.checkPending || doc.checking {
				return false
			}
		}
		return true
	})
}

func TestCloseChecksDiskBeforeWatcherNotification(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "last-copy.txt")
	if err := os.WriteFile(path, []byte("recoverable"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	t.Cleanup(func() {
		if h.app.project != p || p.docs.find(doc.id) != doc {
			return
		}
		defer func() { doc.conflicted = false; h.app.closeProject() }()
		if err := os.WriteFile(path, doc.view.SavedBytes(), 0o600); err != nil {
			t.Error(err)
			return
		}
		awaitDocumentState(t, h, func() bool { return !doc.conflicted })
	})
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	h.app.closeDocument(p, doc.id)
	if p.docs.byPath(path) == nil {
		t.Fatal("closing before the watcher woke discarded the last copy")
	}
	awaitDocumentState(t, h, func() bool { return doc.conflicted })
	if p.docs.byPath(path) != doc {
		t.Fatal("the deleted document was closed after checking disk")
	}
}

func TestProjectCloseChecksDiskBeforeWatcherNotification(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "last-copy.txt")
	if err := os.WriteFile(path, []byte("recoverable"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	t.Cleanup(func() {
		if h.app.project != p || p.docs.find(doc.id) != doc {
			return
		}
		defer func() { doc.conflicted = false; h.app.closeProject() }()
		if err := os.WriteFile(path, doc.view.SavedBytes(), 0o600); err != nil {
			t.Error(err)
			return
		}
		awaitDocumentState(t, h, func() bool { return !doc.conflicted })
	})
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	h.app.closeProject()
	if h.app.project != p {
		t.Fatal("closing the project before watcher delivery discarded the last copy")
	}
	awaitDocumentState(t, h, func() bool { return doc.conflicted && !h.app.closingProject })
	if h.app.project != p || p.docs.byPath(path) != doc {
		t.Fatal("the deleted document did not survive project close")
	}
}

func TestCloseSavesEditsMadeDuringFinalDiskCheck(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	awaitDocumentState(t, h, func() bool {
		slot := p.docs.watches[filepath.Dir(path)]
		if slot == nil {
			return false
		}
		slot.mu.Lock()
		ready := slot.watch != nil && !slot.ready
		slot.mu.Unlock()
		return ready && !doc.checking && !doc.checkPending
	})
	started := make(chan struct{})
	release := make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	var once sync.Once
	h.app.documentReader = func(path string) ([]byte, error) {
		once.Do(func() { close(started); <-release })
		return readDocument(path)
	}
	h.app.closeDocument(p, doc.id)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("final disk check did not start")
	}
	input := doc.view.TextInput(app.TextInputContext{ID: docViews.At(doc.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "latest"}); err != nil {
		t.Fatal(err)
	}
	expected, _ := doc.view.Text()
	close(release)
	released = true
	awaitDocumentState(t, h, func() bool { return p.docs.find(doc.id) == nil })
	disk, err := os.ReadFile(path)
	if err != nil || string(disk) != string(expected) {
		t.Fatalf("saved %q; want %q; error %v", disk, expected, err)
	}
}

func TestDocumentWatchRegistrationFailureIsVisible(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	slot := &documentWatch{}
	p.docs.watches = map[string]*documentWatch{p.root: slot}
	slot.finish(nil, errors.New("watch setup failed"))
	h.app.drainDocumentWatch(p, p.root, slot)
	expected := i18n.Shared(h.app.language(), "desktop.document.watchUnavailable")
	if !strings.Contains(h.app.notice, expected) {
		t.Fatalf("watch failure was hidden: %q", h.app.notice)
	}
}

func TestDocumentsShareDirectoryWatchUntilLastTabCloses(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	paths := []string{filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")}
	for _, path := range paths {
		if err := os.WriteFile(path, []byte("content"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.app.openProject(root)
	p := h.app.project
	for _, path := range paths {
		h.app.openFile(p, path)
	}
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(paths[0]) != nil && p.docs.byPath(paths[1]) != nil })
	first, second := p.docs.byPath(paths[0]), p.docs.byPath(paths[1])
	slot := p.docs.watches[root]
	if slot == nil || len(p.docs.watches) != 1 {
		t.Fatal("documents did not share their parent directory watch")
	}
	h.app.closeDocument(p, first.id)
	awaitDocumentState(t, h, func() bool { return p.docs.find(first.id) == nil })
	if p.docs.watches[root] != slot {
		t.Fatal("closing one tab removed the other tab's watch")
	}
	h.app.closeDocument(p, second.id)
	awaitDocumentState(t, h, func() bool { return p.docs.find(second.id) == nil })
	slot.mu.Lock()
	closed := slot.closed
	slot.mu.Unlock()
	if !closed || len(p.docs.watches) != 0 {
		t.Fatal("last tab left a directory watch behind")
	}
}

func TestProjectCloseSavesEditsMadeDuringFinalDiskCheck(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	doc := p.docs.byPath(path)
	awaitDocumentState(t, h, func() bool {
		slot := p.docs.watches[filepath.Dir(path)]
		if slot == nil {
			return false
		}
		slot.mu.Lock()
		ready := slot.watch != nil && !slot.ready
		slot.mu.Unlock()
		return ready && !doc.checking && !doc.checkPending
	})
	started := make(chan struct{})
	release := make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	var once sync.Once
	h.app.documentReader = func(path string) ([]byte, error) {
		once.Do(func() { close(started); <-release })
		return readDocument(path)
	}
	var allowed bool
	h.app.Config().OnCloseRequest(func() { allowed = true })
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("final project check did not start")
	}
	input := doc.view.TextInput(app.TextInputContext{ID: docViews.At(doc.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "latest"}); err != nil {
		t.Fatal(err)
	}
	expected, _ := doc.view.Text()
	close(release)
	released = true
	awaitDocumentState(t, h, func() bool { return allowed && h.app.project == nil })
	disk, err := os.ReadFile(path)
	if err != nil || string(disk) != string(expected) {
		t.Fatalf("saved %q; want %q; error %v", disk, expected, err)
	}
}

func TestKeepEditorAcknowledgesOnlyObservedDiskVersion(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "conflict.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	d := p.docs.byPath(path)
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "local"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return d.conflicted && !d.checking && !d.checkPending })
	// The test controls the next disk mutation; ignore unrelated queued OS events.
	for _, watch := range p.docs.watches {
		watch.close()
	}
	p.docs.watches = nil
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if !h.shows(i18n.Shared(h.app.language(), "native.keepEditor")) {
		t.Fatal("conflict action not shown in editor")
	}
	h.clickShared("native.keepEditor")
	if d.conflicted || string(d.view.SavedBytes()) != "external" || !d.view.Dirty() {
		t.Fatal("keep did not acknowledge the observed version while retaining local edits")
	}
	if err := os.WriteFile(path, []byte("newer"), 0o600); err != nil {
		t.Fatal(err)
	}
	local, _ := d.view.Text()
	if err := documentio.WriteGuarded(path, local, d.view.SavedBytes()); !errors.Is(err, documentio.ErrConflict) {
		t.Fatalf("saving over a newer disk version returned %v", err)
	}
	if disk, err := os.ReadFile(path); err != nil || string(disk) != "newer" {
		t.Fatalf("newer disk data lost: %q %v", disk, err)
	}
}

func TestLoadDiskDoesNotReplaceInputDuringReadAndCanUndo(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "conflict.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	d := p.docs.byPath(path)
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "local"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return d.conflicted && !d.checking && !d.checkPending })
	// Control the read race independently of later filesystem notifications.
	for _, watch := range p.docs.watches {
		watch.close()
	}
	p.docs.watches = nil
	started, release := make(chan struct{}), make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	h.app.documentReader = func(path string) ([]byte, error) { close(started); <-release; return readDocument(path) }
	h.app.loadDocumentDisk(p, d)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("disk load did not start")
	}
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "more"}); err != nil {
		t.Fatal(err)
	}
	close(release)
	released = true
	awaitDocumentState(t, h, func() bool { return !d.resolvingConflict })
	if text, _ := d.view.Text(); !strings.Contains(string(text), "more") || !d.conflicted {
		t.Fatalf("input during load was lost: %q", text)
	}
	h.app.documentReader = readDocument
	h.app.loadDocumentDisk(p, d)
	awaitDocumentState(t, h, func() bool { return !d.resolvingConflict })
	if text, _ := d.view.Text(); string(text) != "external" || d.conflicted {
		t.Fatalf("disk version not loaded: %q", text)
	}
	if !d.view.Undo() {
		t.Fatal("load discarded undo history")
	}
	if text, _ := d.view.Text(); !strings.Contains(string(text), "more") || !d.view.Dirty() {
		t.Fatalf("undo did not restore local edits: %q", text)
	}
}

func TestAcknowledgedDeletionCanRecreateOnClose(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "deleted.txt")
	if err := os.WriteFile(path, []byte("only copy"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	d := p.docs.byPath(path)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return d.conflicted && d.conflictMissing && !d.checking && !d.checkPending })
	for _, watch := range p.docs.watches {
		watch.close()
	}
	p.docs.watches = nil
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if !h.shows(i18n.Shared(h.app.language(), "native.allowRecreatingFile")) {
		t.Fatal("recreate action not shown in editor")
	}
	h.clickShared("native.allowRecreatingFile")
	if d.conflicted || !d.recreateMissing || !d.dirty() {
		t.Fatal("acknowledged missing file was not marked for recreation")
	}
	h.app.closeDocument(p, d.id)
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(path) == nil })
	if data, err := os.ReadFile(path); err != nil || string(data) != "only copy" {
		t.Fatalf("recreated data = %q, error = %v", data, err)
	}
}

func TestRecreateRejectsFileThatAppearedAfterAcknowledgement(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "deleted.txt")
	if err := os.WriteFile(path, []byte("only copy"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(root)
	h.app.openFile(h.app.project, path)
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(path) != nil })
	p := h.app.project
	d := p.docs.byPath(path)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return d.conflicted && d.conflictMissing && !d.checking && !d.checkPending })
	for _, watch := range p.docs.watches {
		watch.close()
	}
	p.docs.watches = nil
	h.app.keepDocumentEditor(p, d)
	if !d.recreateMissing {
		t.Fatal("deletion was not acknowledged")
	}
	if err := os.WriteFile(path, []byte("new external file"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.saveDocument(p, d.id)
	awaitDocumentState(t, h, func() bool { return !d.saving && d.conflicted && !d.checking && !d.checkPending })
	if data, err := os.ReadFile(path); err != nil || string(data) != "new external file" {
		t.Fatalf("concurrent file lost: %q, %v", data, err)
	}
	if data, _ := d.view.Text(); string(data) != "only copy" {
		t.Fatalf("editor content lost: %q", data)
	}
	// If the newly appeared file disappears again, the conflict must describe
	// that latest observation instead of retaining the obsolete disk version.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	d.checkPending = true
	h.app.scheduleDocumentChecks(p)
	awaitDocumentState(t, h, func() bool { return d.conflictMissing && !d.checking && !d.checkPending })
	if !d.conflicted {
		t.Fatal("a second deletion silently cleared the unresolved conflict")
	}
}
