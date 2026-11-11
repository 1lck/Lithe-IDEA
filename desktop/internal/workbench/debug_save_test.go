package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vivaui/viva/app"
)

// Starting a debug session saves dirty documents first: the debuggee loads the
// files on disk, not the editor buffers.
func TestDebugStartSavesDirtyDocumentsFirst(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "tests", "debug_source.go")
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()
	d := p.docs.byPath(source)
	if d == nil {
		t.Fatal("missing document")
	}
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "// edited\n"}); err != nil {
		t.Fatal(err)
	}
	if !d.dirty() {
		t.Fatal("the edit left the document clean")
	}

	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	awaitDocumentState(t, h, func() bool { return !d.dirty() && !d.saving })
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "// edited") {
		t.Fatalf("the debuggee would read stale bytes: %q", data)
	}

	h.clickNamed(h.app.text.Debug.Stop)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		return p.debug.session == nil
	})
}
