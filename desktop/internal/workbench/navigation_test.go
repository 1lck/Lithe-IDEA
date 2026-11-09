package workbench

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

func TestNavigationDialogSelectsLineAndClampsUTF16Column(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.navigation.delay = -1
	root := t.TempDir()
	path := filepath.Join(root, "example.txt")
	if err := os.WriteFile(path, []byte("first\nA😀中Z\nlast"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	if doc == nil {
		t.Fatal("document did not open")
	}
	awaitDocumentState(t, h, func() bool { return doc.view.Owns(h.driver.Snapshot().Focused) })
	modifier, key := ui.ModifierControl, 'g'
	if runtime.GOOS == "darwin" {
		modifier, key = ui.ModifierMeta, 'l'
	}
	if handled, err := h.driver.ShortcutChord(modifier, key); err != nil || !handled {
		t.Fatalf("shortcut handled=%v err=%v", handled, err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	if got := h.app.navigation.input.Text(); got != "1:1" {
		t.Fatalf("initial input = %q", got)
	}
	if err := h.driver.Type("2"); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.app.navigation.validated == "2" })
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.navigation.open || doc.view.SelectedText() != "A😀中Z" {
		t.Fatalf("line selection = %q open=%v", doc.view.SelectedText(), h.app.navigation.open)
	}
	h.click(center(h.button(itemCaret)))
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	if got := h.app.navigation.input.Text(); got != "2:6" {
		t.Fatalf("initial UTF-16 caret = %q", got)
	}
	if err := h.driver.Type("2:4"); err != nil {
		t.Fatal(err)
	}
	// Enter before validation completes must wait for the matching response.
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !h.app.navigation.open })
	line, col := doc.view.CaretUTF16()
	if line != 1 || col != 3 || doc.view.SelectedText() != "" {
		t.Fatalf("caret = %d:%d selection=%q", line, col, doc.view.SelectedText())
	}
}

type delayedNavigationKernel struct {
	*testKernel
	started, release chan struct{}
}

func (k *delayedNavigationKernel) ParseNavigationInput(ctx context.Context, input string) (*core.NavigationTarget, error) {
	if input == "2" {
		close(k.started)
		<-k.release // Deliberately ignores cancellation to exercise stale replies.
		return &core.NavigationTarget{Line: 1, SelectsWholeLine: true}, nil
	}
	return k.Client.ParseNavigationInput(ctx, input)
}

func TestNavigationDropsStaleValidation(t *testing.T) {
	k := &delayedNavigationKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{}), release: make(chan struct{})}
	h := newHarness(t, k)
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(k.release) }) }
	t.Cleanup(release)
	h.app.navigation.delay = -1
	root := t.TempDir()
	path := filepath.Join(root, "example.txt")
	if err := os.WriteFile(path, []byte("one\ntwo"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	h.click(center(h.button(itemCaret)))
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	if err := h.driver.Type("2"); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	select {
	case <-k.started:
	case <-timer.C:
		t.Fatal("validation did not start")
	}
	if _, err := h.driver.ShortcutChord(ui.ModifierMeta, 'a'); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Type("0"); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.validated == "0" && h.app.navigation.cancel == nil })
	release()
	h.settle()
	if h.app.navigation.target != nil || !h.app.navigation.open {
		t.Fatal("stale valid response replaced invalid input")
	}
}

func TestNavigationClosesWhenSelectedDocumentChanges(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.navigation.delay = -1
	root := t.TempDir()
	first, second := filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")
	for _, path := range []string{first, second} {
		if err := os.WriteFile(path, []byte("one\ntwo"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, first)
	h.settle()
	h.app.openFile(p, second)
	h.settle()
	h.click(center(h.button(itemCaret)))
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil })
	h.app.selectDocument(p, p.docs.byPath(first).id)
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if h.app.navigation.open {
		t.Fatal("dialog survived a document switch")
	}
}

func TestNavigationDialogRejectsInvalidAndCancelPreservesCaret(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.navigation.delay = -1
	root := t.TempDir()
	path := filepath.Join(root, "example.txt")
	if err := os.WriteFile(path, []byte("one\ntwo"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	h.click(center(h.button(itemCaret)))
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	if err := h.driver.Type("0"); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.validated == "0" && h.app.navigation.cancel == nil })
	if !h.app.navigation.open || h.app.navigation.target != nil {
		t.Fatal("invalid input was accepted")
	}
	if err := h.driver.Key(ui.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	line, col := doc.view.CaretUTF16()
	if h.app.navigation.open || line != 0 || col != 0 {
		t.Fatalf("cancel changed caret to %d:%d", line, col)
	}
}

func TestNavigationDialogKeepsTabFocusInside(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.navigation.delay = -1
	root := t.TempDir()
	path := filepath.Join(root, "example.txt")
	if err := os.WriteFile(path, []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	h.click(center(h.button(itemCaret)))
	awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
	for _, want := range []ui.ID{navigationCancel, navigationConfirm, navigationField} {
		if err := h.driver.Key(ui.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
		if got := h.driver.Snapshot().Focused; got != want {
			t.Fatalf("focus = %v, want %v", got, want)
		}
	}
	if err := h.driver.Type("0"); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.navigation.validated == "0" && h.app.navigation.cancel == nil })
	if err := h.driver.Key(ui.KeyTab, ui.ModifierShift); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != navigationCancel {
		t.Fatalf("reverse focus = %v, want cancel", got)
	}
}

func TestNavigationShortcutMatchesPlatformDefaults(t *testing.T) {
	for _, tc := range []struct {
		platform  string
		modifiers ui.Modifiers
		key       string
		want      bool
	}{
		{"darwin", ui.ModifierMeta, "l", true},
		{"darwin", ui.ModifierControl, "g", false},
		{"windows", ui.ModifierControl, "g", true},
		{"windows", ui.ModifierMeta, "l", false},
		{"windows", ui.ModifierControl | ui.ModifierShift, "g", false},
	} {
		if got := isNavigationShortcut(tc.platform, ui.KeyEvent{Modifiers: tc.modifiers, Text: tc.key}); got != tc.want {
			t.Errorf("%+v: got %v", tc, got)
		}
	}
}
