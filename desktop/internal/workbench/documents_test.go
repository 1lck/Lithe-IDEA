package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// The switch at the end of the strip of a group that shows a file turns soft wrapping on and
// off, says which it is to assistive technology, and sits to the right of the file's tab.
func TestSoftWrapSwitchWrapsTheOpenFile(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	path := filepath.Join(project, "long.txt")
	if err := os.WriteFile(path, []byte(strings.Repeat("word ", 400)+"\nend\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.open(project)
	h.app.openFile(h.app.project, path)
	h.settle()

	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the file did not open")
	}
	id := docWrap.At(d.id)
	switchHit := func() ui.Hit {
		t.Helper()
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.ID == id {
				return hit
			}
		}
		t.Fatal("the soft wrap switch is not shown")
		return ui.Hit{}
	}
	hit := switchHit()
	if hit.Label != h.app.text.Editor.SoftWrap || hit.Role != ui.RoleSwitch || hit.Checked {
		t.Fatalf("switch = %q role %v checked %v, want %q, an unchecked switch", hit.Label, hit.Role, hit.Checked, h.app.text.Editor.SoftWrap)
	}
	if tab := h.hit(docTabs.At(d.id)); hit.Bounds.X < tab.X+tab.Width {
		t.Fatalf("the switch at x %v is not right of the file's tab, which ends at %v", hit.Bounds.X, tab.X+tab.Width)
	}

	click := func() {
		t.Helper()
		at := center(switchHit().Bounds)
		if err := h.driver.Click(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	click()
	if !h.app.softWrap || !d.view.Wrap() {
		t.Fatalf("after a click softWrap = %v and the view wraps = %v, want both on", h.app.softWrap, d.view.Wrap())
	}
	if !switchHit().Checked {
		t.Fatal("the switch does not say wrapping is on")
	}
	click()
	if h.app.softWrap || d.view.Wrap() {
		t.Fatalf("after a second click softWrap = %v and the view wraps = %v, want both off", h.app.softWrap, d.view.Wrap())
	}
}

// Closing or replacing a project must not discard a dirty document if its write fails.
func TestProjectSwitchKeepsDirtyDocumentWhenSaveFails(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	folder := filepath.Join(project, "files")
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(folder, "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(project)
	h.app.openFile(h.app.project, path)
	h.settle()
	doc := h.app.project.docs.byPath(path)
	t.Cleanup(func() {
		if err := os.MkdirAll(folder, 0o700); err != nil {
			t.Errorf("restore folder: %v", err)
			return
		}
		if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
			t.Errorf("restore file: %v", err)
			return
		}
		h.app.closeProject()
		h.settle()
	})
	if doc == nil {
		t.Fatal("document was not opened")
	}
	input := doc.view.TextInput(app.TextInputContext{ID: docViews.At(doc.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "changed"}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(folder); err != nil {
		t.Fatal(err)
	}
	h.app.openProject(t.TempDir())
	h.settle()
	if h.app.project == nil || h.app.project.root != project || h.app.project.docs.byPath(path) == nil || !doc.view.Dirty() {
		t.Fatal("project switch discarded the document after its save failed")
	}
}

// A delayed first save must finish before a close saves the later revision.
func TestCloseDocumentSerializesInFlightSave(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("missing document")
	}
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	typeText := func(s string) {
		t.Helper()
		if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: s}); err != nil {
			t.Fatal(err)
		}
	}
	started := make(chan struct{})
	release := make(chan struct{})
	first := true
	h.app.documentWriter = func(path string, data, expected []byte) error {
		if first {
			first = false
			close(started)
			<-release
		}
		return documentio.WriteGuarded(path, data, expected)
	}
	released := false
	t.Cleanup(func() {
		if !released {
			close(release)
		}
	})
	typeText("first")
	h.app.saveDocument(p, d.id)
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("save did not start")
	}
	typeText("second")
	want, _ := d.view.Text()
	h.app.closeDocument(p, d.id)
	if p.docs.find(d.id) == nil {
		t.Fatal("tab closed before save completed")
	}
	close(release)
	released = true
	awaitDocumentState(t, h, func() bool { return p.docs.find(d.id) == nil })
	data, err := os.ReadFile(path)
	if err != nil || string(data) != string(want) {
		t.Fatalf("disk = %q, want %q, error = %v", data, want, err)
	}
}

func TestWindowCloseWaitsForSuccessfulSave(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "change"}); err != nil {
		t.Fatal(err)
	}
	var allowed bool
	h.app.documentWriter = func(string, []byte, []byte) error { return os.ErrPermission }
	h.app.Config().OnCloseRequest(func() { allowed = true })
	h.settle()
	if allowed || h.app.project == nil || !d.view.Dirty() {
		t.Fatal("window close lost unsaved changes after a failed write")
	}
	h.app.documentWriter = documentio.WriteGuarded
	h.app.Config().OnCloseRequest(func() { allowed = true })
	awaitDocumentState(t, h, func() bool { return allowed && h.app.project == nil })
}

// An external edit after opening must not be overwritten by a later editor save.
func TestSaveDoesNotOverwriteExternalChanges(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("document was not opened")
	}
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "local"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.saveDocument(h.app.project, d.id)
	h.settle()
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "external" {
		t.Fatalf("disk = %q, error = %v; external content was overwritten", data, err)
	}
	if !d.view.Dirty() {
		t.Fatal("editor modifications were marked saved after a conflict")
	}
	// Do not discard the dirty buffer on cleanup; restore the baseline so it can be saved.
	t.Cleanup(func() {
		if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
			t.Error(err)
			return
		}
		h.app.closeProject()
		h.settle()
	})
}

// A composition that has not reached the document buffer must not be dropped on close.
func TestCloseKeepsDocumentWhileInputMethodIsComposing(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	input := d.view.TextInput(app.TextInputContext{ID: docViews.At(d.id)})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextSetMarked, Text: "composition"}); err != nil {
		t.Fatal(err)
	}
	h.app.closeDocument(p, d.id)
	if p.docs.find(d.id) == nil {
		t.Fatal("closing discarded an active input-method composition")
	}
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextUnmark}); err != nil {
		t.Fatal(err)
	}
	h.app.closeDocument(p, d.id)
	awaitDocumentState(t, h, func() bool { return p.docs.find(d.id) == nil })
}
