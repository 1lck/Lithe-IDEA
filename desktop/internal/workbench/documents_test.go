package workbench

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// A file in a legacy encoding opens through Core's detection, and saving writes it back in the
// same encoding, so the bytes of an unedited character never change.
func TestOpenDetectsLegacyEncodingAndSavesInIt(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "legacy.txt")
	original := []byte{0xd6, 0xd0, 0xce, 0xc4} // GBK bytes for two Chinese characters.
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	doc := h.app.project.docs.byPath(path)
	if doc == nil {
		t.Fatalf("a GBK file was not opened: %q", h.app.notice)
	}
	if got := doc.view.TextSnapshot().String(); got != "中文" || doc.encodingID() != "gbk" {
		t.Fatalf("text = %q encoding = %s", got, doc.encodingID())
	}
	doc.view.SetSelection(doc.view.TextSnapshot().Len(), doc.view.TextSnapshot().Len())
	h.app.insertForTest(doc, "!")
	h.app.saveDocument(h.app.project, doc.id)
	h.settle()
	data, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(data, append(original, '!')) {
		t.Fatalf("saved bytes = %x, error %v", data, err)
	}
}

func TestReopenAndSaveWithEncoding(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "text.txt")
	if err := os.WriteFile(path, []byte{0xd6, 0xd0, 0xce, 0xc4}, 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	// Reopened as Windows-1252 the same bytes are four Latin letters, not two characters.
	h.app.reopenWithEncoding(p, doc, "windows-1252")
	h.settle()
	if got := doc.view.TextSnapshot().String(); got != "ÖÐÎÄ" || doc.encodingID() != "windows-1252" {
		t.Fatalf("reopened text = %q encoding = %s", got, doc.encodingID())
	}
	// Saving in UTF-8 rewrites the same text as UTF-8 and the document is clean afterwards.
	h.app.saveWithEncoding(p, doc, "utf-8")
	h.settle()
	data, _ := os.ReadFile(path)
	if string(data) != "ÖÐÎÄ" || doc.dirty() || doc.needsCodec() {
		t.Fatalf("after save: %q dirty=%v codec=%v", data, doc.dirty(), doc.needsCodec())
	}
	// A character GBK cannot hold fails the save, writes nothing and brings the encoding back.
	h.app.insertForTest(doc, "😀")
	h.app.saveWithEncoding(p, doc, "gbk")
	h.settle()
	data, _ = os.ReadFile(path)
	if string(data) != "ÖÐÎÄ" || doc.encodingID() != "utf-8" || doc.encodingChanged {
		t.Fatalf("after refused save: %q encoding=%s changed=%v", data, doc.encodingID(), doc.encodingChanged)
	}
	if !strings.Contains(h.app.notice, "GBK") {
		t.Fatalf("notice = %q", h.app.notice)
	}
}

func TestReopenWithEncodingRefusesUnsavedEdits(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "text.txt")
	if err := os.WriteFile(path, []byte("abc"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	h.app.insertForTest(doc, "x")
	h.app.reopenWithEncoding(p, doc, "gbk")
	h.settle()
	if got := doc.view.TextSnapshot().String(); got != "abcx" || !strings.Contains(h.app.notice, "Save or discard") {
		t.Fatalf("text = %q notice = %q", got, h.app.notice)
	}
}

func TestUtf8BOMIsStrippedAndKept(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "bom.txt")
	if err := os.WriteFile(path, []byte("\xef\xbb\xbfhi"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	if got := doc.view.TextSnapshot().String(); got != "hi" || doc.encodingID() != "utf-8-bom" {
		t.Fatalf("text = %q encoding = %s", got, doc.encodingID())
	}
	h.app.insertForTest(doc, "!")
	h.app.saveDocument(p, doc.id)
	h.settle()
	if data, _ := os.ReadFile(path); string(data) != "\xef\xbb\xbfhi!" {
		t.Fatalf("saved = %q", data)
	}
}

func TestReadDocumentUsesWholeFileClassification(t *testing.T) {
	path := filepath.Join(t.TempDir(), "document.txt")
	valid := []byte("中文 and emoji 😀\n")
	if err := os.WriteFile(path, valid, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readDocument(path)
	if err != nil || !bytes.Equal(got, valid) {
		t.Fatalf("valid UTF-8 read = %x, error %v", got, err)
	}
	invalid := append(bytes.Repeat([]byte{'a'}, (8<<10)+1), 0xff)
	if err := os.WriteFile(path, invalid, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readDocument(path); !errors.Is(err, errUnsupportedEncoding) {
		t.Fatalf("invalid UTF-8 after sniff region returned %v", err)
	}
	lateControl := append(bytes.Repeat([]byte{'a'}, (8<<10)+1), 0)
	if err := os.WriteFile(path, lateControl, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readDocument(path); !errors.Is(err, errNotText) {
		t.Fatalf("binary control after the former sniff region returned %v", err)
	}
}

func TestUnsupportedEncodingReasonFollowsLanguage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if got := h.app.documentReason(errUnsupportedEncoding); !strings.Contains(got, "不是有效的 UTF-8") {
		t.Fatalf("Chinese encoding reason = %q", got)
	}
	h.app.setLanguage("en")
	if got := h.app.documentReason(errUnsupportedEncoding); !strings.Contains(got, "not valid UTF-8") {
		t.Fatalf("English encoding reason = %q", got)
	}
}

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
	switchHit := func() gfx.Hit {
		t.Helper()
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.Role == gfx.RoleSwitch && hit.Label == h.app.text.Editor.SoftWrap {
				return hit
			}
		}
		t.Fatal("the soft wrap switch is not shown")
		return gfx.Hit{}
	}
	hit := switchHit()
	if hit.Label != h.app.text.Editor.SoftWrap || hit.Role != gfx.RoleSwitch || hit.Checked {
		t.Fatalf("switch = %q role %v checked %v, want %q, an unchecked switch", hit.Label, hit.Role, hit.Checked, h.app.text.Editor.SoftWrap)
	}
	if tab := h.tabHit(d.name); hit.Bounds.X < tab.X+tab.Width {
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
	input := doc.view.TextInput(app.TextInputContext{ID: doc.hit})
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
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
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
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
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
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
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
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
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

// An open file shows its minimap with the button that hides it, which appears only while the
// pointer is over the minimap. Its click hides the minimap of every editor and keeps the
// choice; the button that shows it again then appears near the text's right edge.
func TestMinimapButtonHidesAndShowsTheMinimap(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	path := filepath.Join(project, "main.go")
	if err := os.WriteFile(path, []byte("package main\n\n"+strings.Repeat("func f() { return }\n", 300)), 0o644); err != nil {
		t.Fatal(err)
	}
	h.open(project)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the file did not open")
	}
	toggle := d.input.Parts().At(1)
	shown := func(id gfx.ID) (gfx.Hit, bool) {
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.ID == id {
				return hit, true
			}
		}
		return gfx.Hit{}, false
	}
	hover := func(at gfx.Point) {
		t.Helper()
		if err := h.driver.Move(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.Advance(400 * time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	click := func(id gfx.ID) {
		t.Helper()
		at := center(h.hit(id))
		if err := h.driver.Click(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}

	minimap := h.hit(d.input.Parts().At(0))
	text := h.hit(d.hit)
	if _, ok := shown(toggle); ok {
		t.Fatal("the minimap's button shows before the pointer is over the minimap")
	}
	hover(gfx.Point{X: text.X + (minimap.X-text.X)/2, Y: text.Y + text.Height/2})
	if _, ok := shown(toggle); ok {
		t.Fatal("the minimap's button shows with the pointer in the middle of the text")
	}
	// The button is reached from the text too: it shows as the pointer nears the minimap.
	hover(gfx.Point{X: minimap.X - 30, Y: text.Y + text.Height/3})
	if button, ok := shown(toggle); !ok || button.Label != h.app.text.Editor.HideMinimap {
		t.Fatalf("near the minimap over the text the button is %+v (shown %v)", button, ok)
	}
	hover(center(minimap))
	button, ok := shown(toggle)
	if !ok {
		t.Fatal("the pointer over the minimap does not show its button")
	}
	if button.Label != h.app.text.Editor.HideMinimap || button.Role != gfx.RoleButton {
		t.Fatalf("button = %q role %v, want %q, a button", button.Label, button.Role, h.app.text.Editor.HideMinimap)
	}
	if button.Bounds.X+button.Bounds.Width > minimap.X+0.5 {
		t.Fatalf("the button ends at %v, over the minimap, which starts at %v", button.Bounds.X+button.Bounds.Width, minimap.X)
	}

	click(toggle)
	if !h.app.settings.HideMinimap {
		t.Fatal("the click did not hide the minimap")
	}
	if _, ok := shown(d.input.Parts().At(0)); ok {
		t.Fatal("the minimap still shows after it was hidden")
	}
	var saved settings
	if found, err := h.store.Load(settingsFile, &saved); err != nil || !found || !saved.HideMinimap {
		t.Fatalf("saved settings = %+v (found %v, %v), want the minimap hidden", saved, found, err)
	}

	// Away from the right edge the button stays hidden; near it, it shows to bring the minimap
	// back.
	hover(gfx.Point{X: text.X + text.Width/2, Y: text.Y + text.Height/2})
	if _, ok := shown(toggle); ok {
		t.Fatal("the button that shows the minimap is out in the middle of the text")
	}
	hover(gfx.Point{X: text.X + text.Width - barTrackForTest - 20, Y: text.Y + text.Height/3})
	button, ok = shown(toggle)
	if !ok || button.Label != h.app.text.Editor.ShowMinimap {
		t.Fatalf("near the right edge the button is %+v (shown %v), want %q", button, ok, h.app.text.Editor.ShowMinimap)
	}
	click(toggle)
	if h.app.settings.HideMinimap {
		t.Fatal("the button did not bring the minimap back")
	}
	if _, ok := shown(d.input.Parts().At(0)); !ok {
		t.Fatal("the minimap is not shown again")
	}
}

// barTrackForTest is the width of the editor's vertical scrollbar track, at the text's right
// edge.
const barTrackForTest = 10

// insertForTest appends text to the document as one edit, as the editor would take typing.
func (a *App) insertForTest(d *document, text string) {
	end := d.view.TextSnapshot().Len()
	if err := d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: end, End: end}, Text: text}}); err != nil {
		panic(err)
	}
}
