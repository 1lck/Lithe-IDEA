package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Running the editor's selection in the terminal opens one more terminal, selected in the
// Terminal tool window, and runs the selection there; the terminal that was open stays in the
// list, so its shell is still the window's to close.
func TestRunSelectionRunsInANewShownTerminal(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses /bin/sh")
	}
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	root := t.TempDir()
	path := filepath.Join(root, "run.sh")
	// The output differs from the typed line, so the shell has run it when it shows.
	if err := os.WriteFile(path, []byte("printf 'LITHE_%s\\n' RAN\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.settings.TerminalShell = "/bin/sh"
	p := h.app.project
	if len(p.terms.list) != 1 {
		t.Fatalf("the project opened with %d terminals, want 1", len(p.terms.list))
	}
	first := p.terms.list[0]
	h.app.openFile(p, path)
	h.await("the file", func() bool {
		d := h.app.selectedEditorDocument()
		return d != nil && d.path == path
	})
	d := h.app.selectedEditorDocument()
	d.view.SetSelection(0, d.view.TextSnapshot().Len())
	var run func()
	for _, cmd := range h.app.commands() {
		if cmd.id == "terminal.runSelection" {
			run = cmd.run
		}
	}
	if run == nil {
		t.Fatal("Run Selection is not offered for a selection")
	}
	run()
	h.settle()

	if len(p.terms.list) != 2 || p.terms.list[0] != first {
		t.Fatalf("after Run Selection the project has %d terminals, first kept %v", len(p.terms.list), p.terms.list[0] == first)
	}
	term := p.terms.list[1]
	if p.terms.selected(toolGroup) != term || !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		t.Fatal("the terminal the selection runs in is not shown")
	}
	awaitStateWithin(t, h, 5*time.Second, "the selection's output", func() bool {
		term.view.Pump()
		return strings.Contains(term.view.RetainedText(1<<16), "LITHE_RAN")
	})
}
