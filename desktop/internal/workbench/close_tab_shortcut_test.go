package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
)

// Close Tab runs on Command-W by default only on macOS; elsewhere it has no default chord.
func TestCloseTabDefaultsToCommandWOnlyOnMacOS(t *testing.T) {
	action, ok := shortcuts.Find(shortcuts.CloseTab)
	if !ok {
		t.Fatal("Close Tab is not in the shortcut catalog")
	}
	if runtime.GOOS != "darwin" {
		if len(action.Defaults) != 0 {
			t.Fatalf("Close Tab defaults to %v outside macOS", action.Defaults)
		}
		return
	}
	want, _ := keymap.Parse(gfx.ModifierMeta, "w")
	if !slices.Equal(action.Defaults, []keymap.Chord{want}) {
		t.Fatalf("Close Tab defaults to %v on macOS, not Command-W", action.Defaults)
	}
}

// closeTabChord is the chord Close Tab runs on in a test: its default, Command-W, on macOS;
// elsewhere, where it has none, Control-W bound as the Keymap page binds it.
func closeTabChord(t *testing.T, a *App) keymap.Chord {
	t.Helper()
	if runtime.GOOS == "darwin" {
		chord, _ := keymap.Parse(gfx.ModifierMeta, "w")
		return chord
	}
	chord := controlW(t)
	a.settings.Keymap = a.settings.Keymap.With(shortcuts.CloseTab, []keymap.Chord{chord})
	return chord
}

func controlW(t *testing.T) keymap.Chord {
	t.Helper()
	chord, ok := keymap.Parse(gfx.ModifierControl, "w")
	if !ok {
		t.Fatal("Control-W is not a chord")
	}
	return chord
}

func pressCloseTab(t *testing.T, h *harness, chord keymap.Chord) {
	t.Helper()
	if _, err := h.driver.ShortcutChord(chord.Modifiers, 'w'); err != nil {
		t.Fatal(err)
	}
	h.settle()
}

// The chord closes the tab the editor group shows, here the LSP Logs tab, and then the file.
func TestCloseTabShortcutClosesTheSelectedEditorTab(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	group := f.p.terms.bench.GroupOf(lspLogMember).ID
	if runtime.GOOS != "darwin" {
		// Without a binding of the user's, Control-W leaves the tab open.
		pressCloseTab(t, f.h, controlW(t))
		if lspLogTabs(f.p) != 1 {
			t.Fatal("Control-W closed the tab with no binding")
		}
	}
	chord := closeTabChord(t, a)
	pressCloseTab(t, f.h, chord)
	if lspLogTabs(f.p) != 0 || f.p.selectedDocument(group) != f.d {
		t.Fatalf("after the chord: %d log tabs, the file selected %v", lspLogTabs(f.p), f.p.selectedDocument(group) == f.d)
	}
	pressCloseTab(t, f.h, chord)
	if f.p.docs.find(f.d.id) != nil {
		t.Fatal("the chord did not close the file's tab")
	}
}

// With a terminal focused the chord closes the terminal's tab, not the file's tab in the editor.
func TestCloseTabShortcutClosesTheFocusedTerminal(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "main.txt")
	if err := os.WriteFile(path, []byte("text\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.app.reduceChrome(core.SetChromeOpen(itemTerminal, true))
		h.settle()
	}
	h.app.openFile(p, path)
	h.settle()
	if len(p.terms.list) != 1 {
		t.Fatalf("the Terminal tool window opened %d terminals", len(p.terms.list))
	}
	term := p.terms.list[0]
	h.app.focusTerminal(term.id)
	h.settle()
	awaitDocumentState(t, h, func() bool { return term.view.Owns(h.driver.Snapshot().Focused) })
	pressCloseTab(t, h, closeTabChord(t, h.app))
	awaitDocumentState(t, h, func() bool { return p.terms.find(term.id) == nil })
	if p.docs.byPath(path) == nil {
		t.Fatal("the chord in a terminal closed the file's tab")
	}
}
