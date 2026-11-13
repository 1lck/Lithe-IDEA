package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/draftstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/keymap"
)

func essentialsDocument(t *testing.T, text string) (*harness, *project, *document) {
	t.Helper()
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.settings.DisableAutoSave = true
	root := t.TempDir()
	path := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("document did not open")
	}
	return h, p, d
}
func TestEditorEssentialsFindReplaceNativeFlow(t *testing.T) {
	h, p, d := essentialsDocument(t, "alpha 😀 alpha\nALPHA beta")
	d.view.SetSelection(0, 0)
	d.find.debounce = -1
	if _, err := h.driver.ShortcutChord(keymap.Primary, 'f'); err != nil {
		t.Fatal(err)
	}
	if !d.find.open {
		t.Fatal("find shortcut did not open the bar")
	}
	d.find.query.SetText("alpha")
	h.app.refreshEditorFind(p, d)
	h.await("Unicode matches", func() bool { return !d.find.pending && len(d.find.matches) == 3 })
	h.app.stepEditorFind(d, 1)
	start, end := d.view.Selection()
	if start != 11 || end != 16 {
		t.Fatalf("next match %d..%d", start, end)
	}
	h.app.openEditorFind(true)
	d.find.replacement.SetText("omega")
	h.settleChain()
	h.clickNamed(h.shared("desktop.editorFind.replaceAll"))
	h.await("atomic replacement", func() bool { return d.view.TextSnapshot().String() == "omega 😀 omega\nomega beta" })
	d.view.Undo()
	if got := d.view.TextSnapshot().String(); got != "alpha 😀 alpha\nALPHA beta" {
		t.Fatalf("bulk undo: %q", got)
	}
	d.find.regex = true
	d.find.query.SetText("[")
	h.app.refreshEditorFind(p, d)
	h.await("invalid pattern", func() bool { return !d.find.pending && d.find.failure == "invalid_pattern" })
	if got := d.view.TextSnapshot().String(); got != "alpha 😀 alpha\nALPHA beta" {
		t.Fatal("invalid regex changed text")
	}
	h.app.closeEditorFind(d)
	if d.find.open || d.find.timer != nil || d.find.cancel != nil {
		t.Fatal("find retained resources")
	}
}
func TestEditorEssentialsFindRejectsLateReplacement(t *testing.T) {
	h, p, d := essentialsDocument(t, "one one")
	d.find.open = true
	before := d.view.TextSnapshot()
	baseline := d.view.SavedSnapshot()
	prepared, err := editorview.PrepareEdits(before, baseline, []editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 3}, Text: "two"}})
	if err != nil {
		t.Fatal(err)
	}
	d.find.generation = 5
	h.app.insertForTest(d, "!")
	h.app.applyEditorFind(p, d, before, 5, true, core.EditorFindResult{Edits: []core.EditorReplacement{{EditorByteRange: core.EditorByteRange{Start: 0, End: 3}, Text: "two"}}}, prepared, nil)
	if got := d.view.TextSnapshot().String(); got != "one one!" {
		t.Fatalf("stale replacement overwrote edits: %q", got)
	}
}
func TestEditorEssentialsRecoveryRestartsAndProtectsChangedDisk(t *testing.T) {
	h, p, d := essentialsDocument(t, "disk baseline")
	h.app.insertForTest(d, " + unsaved 😀")
	h.app.flushCheckpoint(p, d, false)
	h.settleChain()
	storage := draftstore.New(h.store.Dir(), core.EditorRecoveryDecision{MaxDocumentBytes: 64 << 20, MaxStorageBytes: 256 << 20, MaxDocuments: 64})
	entry, found, err := storage.Load(p.root, d.path)
	if err != nil || !found || entry.Text != "disk baseline + unsaved 😀" {
		t.Fatalf("durable checkpoint: %+v %v %v", entry, found, err)
	}
	// A fresh view and a fresh storage owner simulate loss of the process, not normal close.
	if err = os.WriteFile(d.path, []byte("external change"), 0600); err != nil {
		t.Fatal(err)
	}
	restored := h.app.prepareRecoveredDocument(context.Background(), p, d.path, []byte("external change"), nil)
	h.app.removeDocument(p, d)
	h.settleChain() // remove may enqueue; the durable restored snapshot is already captured.
	h.app.placeDocument(p, d.path, d.name, restored.disk, nil, "")
	reopened := p.docs.byPath(d.path)
	h.app.applyRecoveredDocument(p, reopened, restored)
	if !reopened.conflicted || reopened.view.TextSnapshot().String() != entry.Text {
		t.Fatal("changed disk was not presented as a recovered conflict")
	}
	h.app.saveDocumentMode(p, reopened.id, true)
	h.settleChain()
	disk, err := os.ReadFile(d.path)
	if err != nil || string(disk) != "external change" {
		t.Fatalf("recovery overwrote external data: %q %v", disk, err)
	}
	// Resolve explicitly so the harness can finish a normal close.
	h.app.keepDocumentEditor(p, reopened)
	h.app.saveDocument(p, reopened.id)
	h.settleChain()
	_, found, err = storage.Load(p.root, d.path)
	if err != nil || found {
		t.Fatalf("saved checkpoint remains: %v %v", found, err)
	}
}
func TestEditorEssentialsScratchKeepsAndDiscardsAcrossOwners(t *testing.T) {
	h, p, _ := essentialsDocument(t, "base")
	h.app.newScratch(p)
	d := p.selectedDocument(p.docs.group)
	if d == nil || !d.scratch {
		t.Fatal("scratch missing")
	}
	h.app.insertForTest(d, "draft before a destination 😀")
	path := d.path
	h.app.closeDocument(p, d.id)
	h.settleChain()
	if p.docs.byPath(path) != nil {
		t.Fatal("close did not keep draft independently of tab")
	}
	h.app.openScratchList()
	h.settleChain()
	if len(h.app.drafts.entries) != 1 {
		t.Fatalf("scratch list %+v", h.app.drafts.entries)
	}
	h.app.drafts.open = false
	h.app.openScratch(p, path)
	h.settleChain()
	d = p.docs.byPath(path)
	if d == nil || d.view.TextSnapshot().String() != "draft before a destination 😀" {
		t.Fatal("reopened scratch lost content")
	}
	destination := filepath.Join(t.TempDir(), "saved.txt")
	h.app.chooseScratchPath = func(string, string) (string, error) { return destination, nil }
	h.app.saveScratchAs(p, d)
	h.settleChain()
	if p.docs.byPath(path) != nil || p.docs.byPath(destination) == nil {
		t.Fatal("Save As did not replace scratch with destination")
	}
	h.app.newScratch(p)
	d = p.selectedDocument(p.docs.group)
	h.app.insertForTest(d, "discard me")
	disk, err := os.ReadFile(destination)
	if err != nil || string(disk) != "draft before a destination 😀" {
		t.Fatalf("Save As: %q %v", disk, err)
	}
	h.app.discardScratch(p, d)
	h.settleChain()
	entries, err := h.app.recovery.store.List("", true)
	if err != nil || len(entries) != 0 {
		t.Fatalf("discard retained draft: %+v %v", entries, err)
	}
}
func TestEditorEssentialsRecentFilesKeepEditOrderAndCaret(t *testing.T) {
	h, p, d := essentialsDocument(t, "first\nsecond")
	h.app.insertForTest(d, "!")
	path := filepath.Join(p.root, "other.txt")
	if err := os.WriteFile(path, []byte("other"), 0600); err != nil {
		t.Fatal(err)
	}
	h.app.openFile(p, path)
	h.settleChain()
	h.app.openRecentFiles(false)
	h.settleChain()
	if len(h.app.recentFiles.list) != 2 || h.app.recentFiles.list[0].Name != "other.txt" {
		t.Fatalf("open MRU %+v", h.app.recentFiles.list)
	}
	h.app.openRecentFiles(true)
	h.settleChain()
	if len(h.app.recentFiles.list) != 1 || h.app.recentFiles.list[0].Name != "notes.txt" {
		t.Fatalf("edit MRU %+v", h.app.recentFiles.list)
	}
	h.app.recentFiles.query.SetText("missing")
	h.app.queryRecentFiles(p)
	h.settleChain()
	if len(h.app.recentFiles.list) != 0 {
		t.Fatal("filter retained unmatched files")
	}
	h.app.recentFiles.open = false
}

func TestEditorEssentialsAutomaticRecoveryRequiresExplicitDecision(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.settings.DisableAutoSave = true
	root := t.TempDir()
	path := filepath.Join(root, "recovered.txt")
	if err := os.WriteFile(path, []byte("external"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := h.app.recovery.store.Save(draftstore.Entry{Root: root, Path: path, Name: "recovered.txt", BaseHash: draftstore.Hash([]byte("before crash")), Text: "unsaved 😀"}); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.settleChain()
	p := h.app.project
	d := p.docs.byPath(path)
	if d == nil || !d.dirty() || !d.conflicted || !d.recoveredConflict {
		t.Fatal("startup did not restore a pending conflict")
	}
	h.await("initial native disk observation", func() bool { return !d.checkPending && !d.checking })
	if !d.conflicted {
		t.Fatal("watcher acknowledged recovery without user choice")
	}
	h.app.saveDocument(p, d.id)
	h.settleChain()
	disk, err := os.ReadFile(path)
	if err != nil || string(disk) != "external" {
		t.Fatalf("manual save bypassed conflict: %q %v", disk, err)
	}
	h.app.keepDocumentEditor(p, d)
	h.app.saveDocument(p, d.id)
	h.settleChain()
	disk, err = os.ReadFile(path)
	if err != nil || string(disk) != "unsaved 😀" || d.conflicted {
		t.Fatalf("explicit keep/save: %q %v", disk, err)
	}
}

func TestEditorEssentialsSelectionScopeFollowsBulkReplacement(t *testing.T) {
	h, p, d := essentialsDocument(t, "one one one")
	d.view.SetSelection(0, 7)
	d.find.debounce = -1
	h.app.openEditorFind(true)
	d.find.selection = true
	d.find.query.SetText("one")
	d.find.replacement.SetText("a")
	h.app.refreshEditorFind(p, d)
	h.await("scoped matches", func() bool { return !d.find.pending && len(d.find.matches) == 2 })
	h.app.invalidator.Invalidate()
	h.settleChain()
	h.clickNamed(h.shared("desktop.editorFind.replaceAll"))
	h.await("scoped replacement", func() bool { return d.view.TextSnapshot().String() == "a a one" && !d.find.pending })
	if d.find.scope == nil || d.find.scope.Start != 0 || d.find.scope.End != 3 || d.find.failure != "" {
		t.Fatalf("scope after replacement: %+v failure=%s", d.find.scope, d.find.failure)
	}
}

func TestEditorEssentialsClosingProjectDropsDialogsAndStartsNewEditVisit(t *testing.T) {
	h, p, d := essentialsDocument(t, "first")
	h.app.insertForTest(d, "!")
	h.app.openRecentFiles(false)
	h.app.openScratchList()
	h.settleChain()
	h.app.closeProject()
	h.await("project closed", func() bool { return h.app.project == nil })
	if h.app.recentFiles.open || h.app.drafts.open || h.app.recentFiles.lastEdited != 0 {
		t.Fatal("closed project retained its dialogs or editing visit")
	}
	root := t.TempDir()
	path := filepath.Join(root, "second.txt")
	if err := os.WriteFile(path, []byte("second"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p = h.app.project
	h.app.openFile(p, path)
	h.settleChain()
	d = p.docs.byPath(path)
	h.app.insertForTest(d, "!")
	h.app.saveDocument(p, d.id)
	h.settleChain()
	h.app.openRecentFiles(true)
	h.settleChain()
	if len(h.app.recentFiles.list) != 1 || h.app.recentFiles.list[0].Name != "second.txt" {
		t.Fatalf("new project edit visit: %+v", h.app.recentFiles.list)
	}
	h.app.recentFiles.open = false
}
