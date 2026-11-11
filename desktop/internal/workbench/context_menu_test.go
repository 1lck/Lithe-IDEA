package workbench

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// rightClickAt opens the context menu of whatever is laid out at the center of bounds.
func (h *harness) rightClickAt(bounds gfx.Rect) {
	h.t.Helper()
	point := center(bounds)
	if err := h.driver.ClickButton(point.X, point.Y, gfx.PointerButtonSecondary); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

// The menu of a change row in the Commit window stages the change and copies its path, as the
// old client's change list did.
func TestCommitChangeMenuStagesAndCopiesThePath(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	h.rightClickNamed("changed.txt")
	h.click(center(h.popupHit(h.shared("native.copyPath"))))
	want := filepath.Join(p.git.repositoryRoot(p.root), "changed.txt")
	if got := h.driver.Clipboard(); got != want {
		t.Fatalf("the clipboard holds %q, want %q", got, want)
	}

	h.rightClickNamed("changed.txt")
	h.click(center(h.popupHit(h.shared("desktop.files.stage"))))
	h.await("the staged change", func() bool {
		return gitRun(t, dir, "diff", "--cached", "--name-only") == "changed.txt"
	})
}

// The terminal's menu selects everything the shell printed and copies it.
func TestTerminalMenuSelectsAllAndCopies(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	term := busyTerminal(t, h, "printf 'menu-marker\\n'; read line")
	h.await("the shell's output", func() bool { return strings.Contains(term.view.RetainedText(1<<16), "menu-marker") })

	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.app.reduceChrome(core.SetChromeOpen(itemTerminal, true))
	}
	h.settle()
	if term.hit.IsZero() {
		t.Fatal("the terminal is not shown")
	}
	h.rightClickAt(h.topHit(term.hit))
	h.click(center(h.popupHit(h.shared("menu.selectAll"))))
	if !term.view.HasSelection() {
		t.Fatal("Select All selected nothing")
	}
	h.rightClickAt(h.topHit(term.hit))
	h.click(center(h.popupHit(h.shared("menu.copy"))))
	if got := h.driver.Clipboard(); !strings.Contains(got, "menu-marker") {
		t.Fatalf("the clipboard holds %q, want the shell's output", got)
	}

	// The shell waits in its own builtin, so the menu's Close asks nothing.
	h.rightClickAt(h.topHit(term.hit))
	h.click(center(h.popupHit(h.shared("terminal.contextClose"))))
	h.await("the closed terminal", func() bool { return h.app.project.terms.find(term.id) == nil })
}
