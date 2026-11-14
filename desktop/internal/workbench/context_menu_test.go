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
	h.clickNamed(h.shared("native.copyPathReference"))
	h.clickNamed(h.shared("native.copyPath"))
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

func TestRunConsoleMenuCopiesTheChosenLineAndTheWholeOutput(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	run := &runEntry{id: "run-1", label: "Serve"}
	run.append("first line\nsecond line\n")
	p.build.runs = append(p.build.runs, run)
	p.build.view = run.id
	if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
		h.app.reduceChrome(core.SetChromeOpen(itemRun, true))
	}
	h.settle()

	line := h.topHit(run.list.RowID(1))
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("menu.copy"))))
	if got := h.driver.Clipboard(); got != "second line" {
		t.Fatalf("Copy put %q on the clipboard, want the chosen line", got)
	}
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("git.console.copyOutput"))))
	if got := h.driver.Clipboard(); got != "first line\nsecond line\n" {
		t.Fatalf("Copy Output put %q on the clipboard, want the whole output", got)
	}
}

func TestEditorCopyPathSubmenuKeepsAbsoluteAndRelativeActions(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	root := newTestRepository(t)
	p := h.openTree(t, root)
	h.app.openFile(p, filepath.Join(root, "changed.txt"))
	h.settleChain()
	h.rightClickAt(h.tabHit("changed.txt"))
	h.clickNamed(h.shared("native.copyPathReference"))
	h.clickNamed(h.shared("native.copyRelativePath"))
	if got := h.driver.Clipboard(); got != "changed.txt" {
		t.Fatalf("copied relative path %q", got)
	}
}
