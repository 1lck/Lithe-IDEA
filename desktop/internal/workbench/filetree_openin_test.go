package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileapps"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// treeAppsStub answers Open With in place of the system for one test: list is what the
// system offers for every file, and the files asked about and the files opened are recorded.
type treeAppsStub struct {
	mu     sync.Mutex
	list   []fileapps.App
	err    error
	open   error
	asked  []string
	opened []string
}

func stubTreeApps(t *testing.T, list []fileapps.App, err error) *treeAppsStub {
	t.Helper()
	s := &treeAppsStub{list: list, err: err}
	previousList, previousOpen := treeFileApps, treeOpenWithApp
	treeFileApps = func(path string) ([]fileapps.App, error) {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.asked = append(s.asked, path)
		return slices.Clone(s.list), s.err
	}
	treeOpenWithApp = func(path string, chosen fileapps.App) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.opened = append(s.opened, path+" with "+chosen.ID)
		return s.open
	}
	t.Cleanup(func() { treeFileApps, treeOpenWithApp = previousList, previousOpen })
	return s
}

func (s *treeAppsStub) record() (asked, opened []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.asked), slices.Clone(s.opened)
}

// popupClick clicks the item named label of the open menu or submenu.
func (h *harness) popupClick(label string) {
	h.t.Helper()
	h.click(center(h.popupHit(label)))
}

// popupRest rests the pointer on the item named label of the open menu or submenu longer than
// a submenu takes to open, as a user moving down the menu does instead of clicking. The
// submenu then opens in a paint that delivers no click.
func (h *harness) popupRest(label string) {
	h.t.Helper()
	at := center(h.popupHit(label))
	if err := h.driver.Move(at.X, at.Y); err != nil {
		h.t.Fatalf("Move: %v", err)
	}
	if err := h.driver.Advance(150 * time.Millisecond); err != nil {
		h.t.Fatalf("Advance: %v", err)
	}
}

// Open In replaces Reveal in Finder and Open With… on a file's row. Open With lists what the
// system offers, as Finder's Open With menu does: the default first, then the others, with
// the folder beside a name two applications share, then Other…; choosing one opens the file
// with it.
func TestProjectTreeOpenWithListsTheSystemsApplications(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "notes.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)
	appsDir := filepath.Join(root, "Apps")
	otherDir := filepath.Join(root, "Other")
	otherViewer := filepath.Join(otherDir, "Viewer.app")
	stub := stubTreeApps(t, []fileapps.App{
		{ID: filepath.Join(appsDir, "Editor.app"), Name: "Editor.app", Default: true},
		{ID: filepath.Join(appsDir, "Viewer.app"), Name: "Viewer.app"},
		{ID: otherViewer, Name: "Viewer.app"},
	}, nil)
	language := h.app.language()
	file := filepath.Join(root, "notes.txt")

	h.rightClickNamed("notes.txt")
	for _, gone := range []string{revealLabel(language), h.shared("desktop.files.openWith")} {
		if h.hasPopupItem(gone) {
			t.Fatalf("the row menu still lists %q at its top level", gone)
		}
	}
	h.popupClick(h.shared("desktop.files.openIn"))
	for _, item := range []string{h.shared("desktop.files.openWith"), fileManagerLabel(language), h.shared("desktop.files.openInTerminal")} {
		if !h.hasPopupItem(item) {
			t.Fatalf("Open In does not list %q", item)
		}
	}
	h.popupClick(h.shared("desktop.files.openWith"))
	other := i18n.SharedFormat(language, "desktop.files.openWithAppPath", map[string]string{"name": "Viewer.app", "path": otherDir})
	for _, item := range []string{
		i18n.SharedFormat(language, "desktop.files.openWithDefault", map[string]string{"name": "Editor.app"}),
		i18n.SharedFormat(language, "desktop.files.openWithAppPath", map[string]string{"name": "Viewer.app", "path": appsDir}),
		other,
		h.shared("desktop.files.openWithOther"),
	} {
		if !h.hasPopupItem(item) {
			t.Fatalf("Open With does not list %q", item)
		}
	}
	if h.hasPopupItem(h.shared("desktop.files.openWithFinding")) {
		t.Fatal("Open With still says it is finding applications after the system answered")
	}
	h.popupClick(other)
	h.await("the file to be opened", func() bool {
		_, opened := stub.record()
		return len(opened) == 1
	})
	asked, opened := stub.record()
	if want := []string{file}; !slices.Equal(asked, want) {
		t.Fatalf("asked the system about %q, want %q once", asked, want)
	}
	if want := []string{file + " with " + otherViewer}; !slices.Equal(opened, want) {
		t.Fatalf("opened %q, want %q", opened, want)
	}
	if h.app.notice != "" {
		t.Fatalf("notice = %q, want none", h.app.notice)
	}
}

// Open In opened by resting the pointer on it, as it is usually opened, asks the system too:
// Open With lists the applications instead of saying it is finding them forever.
func TestProjectTreeOpenWithListsTheApplicationsWhenOpenedByHover(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "notes.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)
	stub := stubTreeApps(t, []fileapps.App{{ID: "/Apps/Editor.app", Name: "Editor.app", Default: true}}, nil)
	language := h.app.language()

	h.rightClickNamed("notes.txt")
	h.popupRest(h.shared("desktop.files.openIn"))
	h.popupRest(h.shared("desktop.files.openWith"))
	h.settle()
	if asked, _ := stub.record(); !slices.Equal(asked, []string{filepath.Join(root, "notes.txt")}) {
		t.Fatalf("Open In opened by hover asked the system about %q, want the file once", asked)
	}
	editor := i18n.SharedFormat(language, "desktop.files.openWithDefault", map[string]string{"name": "Editor.app"})
	if !h.hasPopupItem(editor) || h.hasPopupItem(h.shared("desktop.files.openWithFinding")) {
		t.Fatalf("Open With opened by hover does not list %q, or still says it is finding applications", editor)
	}
}

// A folder's and the root's Open In have no Open With; a system that offers no application,
// or fails to answer, leaves Other… alone.
func TestProjectTreeOpenInWithoutApplications(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "src/a.txt", "notes.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	stub := stubTreeApps(t, nil, nil)

	for _, row := range []string{"src", p.tree.root.name} {
		h.rightClickNamed(row)
		h.popupClick(h.shared("desktop.files.openIn"))
		if h.hasPopupItem(h.shared("desktop.files.openWith")) {
			t.Fatalf("Open In of %q lists Open With", row)
		}
		if !h.hasPopupItem(fileManagerLabel(h.app.language())) || !h.hasPopupItem(h.shared("desktop.files.openInTerminal")) {
			t.Fatalf("Open In of %q lacks the file manager or the terminal", row)
		}
		if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	if asked, _ := stub.record(); len(asked) != 0 {
		t.Fatalf("a folder's menu asked the system about %q", asked)
	}

	for _, err := range []error{nil, errors.New("database unavailable")} {
		stub.mu.Lock()
		stub.err = err
		stub.mu.Unlock()
		h.rightClickNamed("notes.txt")
		h.popupClick(h.shared("desktop.files.openIn"))
		h.popupClick(h.shared("desktop.files.openWith"))
		if !h.hasPopupItem(h.shared("desktop.files.openWithOther")) || h.hasPopupItem(h.shared("desktop.files.openWithFinding")) {
			t.Fatalf("with the answer %v, Open With is not Other… alone", err)
		}
		if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
}

// Choosing an application the system no longer offers names it; any other failure gives the
// system's reason.
func TestProjectTreeOpenWithReportsFailures(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "notes.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)
	stub := stubTreeApps(t, nil, nil)
	file := filepath.Join(root, "notes.txt")
	chosen := fileapps.App{ID: "/Apps/Viewer.app", Name: "Viewer.app"}
	language := h.app.language()

	for _, tc := range []struct {
		err  error
		want string
	}{
		{fileapps.ErrNotOffered, i18n.SharedFormat(language, "desktop.files.openWithGone", map[string]string{"name": "Viewer.app"})},
		{errors.New("launch failed"), i18n.SharedFormat(language, "desktop.files.openWithFailed", map[string]string{"reason": "launch failed"})},
	} {
		stub.mu.Lock()
		stub.open = tc.err
		stub.mu.Unlock()
		h.app.notice = ""
		h.app.openTreeFileWithApp(file, chosen)
		h.settle()
		if h.app.notice != tc.want {
			t.Fatalf("notice = %q, want %q", h.app.notice, tc.want)
		}
	}
}

// The file manager item shows the row, as Reveal in Finder did.
func TestProjectTreeOpenInShowsTheRowInTheFileManager(t *testing.T) {
	root := t.TempDir()
	writeTreeFiles(t, root, "notes.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.openTree(t, root)
	stubTreeApps(t, nil, nil)
	var revealed []string
	previous := treeRevealPath
	treeRevealPath = func(full string) error {
		revealed = append(revealed, full)
		return nil
	}
	t.Cleanup(func() { treeRevealPath = previous })

	h.rightClickNamed("notes.txt")
	h.popupClick(h.shared("desktop.files.openIn"))
	h.popupClick(fileManagerLabel(h.app.language()))
	if want := []string{filepath.Join(root, "notes.txt")}; !slices.Equal(revealed, want) {
		t.Fatalf("revealed %q, want %q", revealed, want)
	}
}

// Terminal opens a terminal in the Terminal tool window, in the folder of a folder's row and
// in the folder of a file's row, and gives it the keyboard.
func TestProjectTreeOpenInTerminalStartsInTheRowsFolder(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	root := t.TempDir()
	writeTreeFiles(t, root, "src/deep/a.txt")
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p := h.openTree(t, root)
	stubTreeApps(t, nil, nil)
	h.app.expandProjectTree(p)
	awaitDocumentState(t, h, func() bool { return !p.tree.expandingAll && p.tree.find("src/deep/a.txt") != nil })
	h.settle()
	// The shell writes where it started and stays, so the terminal does not end.
	scripts := t.TempDir()
	out := filepath.Join(scripts, "cwd")
	shell := filepath.Join(scripts, "shell.sh")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\npwd -P > '"+out+"'\nexec cat\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	h.app.settings.TerminalShell = shell

	for _, tc := range []struct{ row, folder string }{
		{"src", filepath.Join(root, "src")},
		{"a.txt", filepath.Join(root, "src", "deep")},
	} {
		_ = os.Remove(out)
		before := len(p.terms.list)
		h.rightClickNamed(tc.row)
		h.popupClick(h.shared("desktop.files.openIn"))
		h.popupClick(h.shared("desktop.files.openInTerminal"))
		if len(p.terms.list) != before+1 {
			t.Fatalf("Terminal on %q opened %d terminals, want one", tc.row, len(p.terms.list)-before)
		}
		opened := p.terms.list[len(p.terms.list)-1]
		if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
			t.Fatalf("Terminal on %q left the Terminal tool window closed", tc.row)
		}
		if h.app.focus.term != opened.id {
			t.Fatalf("Terminal on %q did not give the new terminal the keyboard", tc.row)
		}
		want, err := filepath.EvalSymlinks(tc.folder)
		if err != nil {
			t.Fatal(err)
		}
		var started string
		awaitStateWithin(t, h, 10*time.Second, "the shell of "+tc.row+" to start", func() bool {
			data, err := os.ReadFile(out)
			started = strings.TrimSpace(string(data))
			return err == nil && started != ""
		})
		if started != want {
			t.Fatalf("Terminal on %q started in %q, want %q", tc.row, started, want)
		}
	}
}
