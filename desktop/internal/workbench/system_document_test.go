package workbench

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSystemDocumentsPreserveProjectAndReuseIsolatedSession(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	path := filepath.Join(t.TempDir(), "中文 source.go")
	second := filepath.Join(t.TempDir(), "another.txt")
	for _, name := range []string{path, second} {
		if err := os.WriteFile(name, []byte("// document\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	s := h.app.sessions
	h.app.openSystemDocument(path)
	h.await("system document", func() bool {
		return s.active != h.app && s.active.project != nil && s.active.project.docs.byPath(path) != nil
	})
	standalone := s.active
	if len(s.list) != 2 || !standalone.documentOnly || standalone.plugins != nil || standalone.aiKernel != nil || !standalone.project.standalone {
		t.Fatal("system document did not get an isolated editor session")
	}
	if h.app.project == nil || h.app.project.root != alpha || standalone.project.search.watch != nil {
		t.Fatal("opening a system document replaced the project or started indexing")
	}
	h.clickNamed("alpha")
	h.await("project tab", func() bool { return s.active == h.app })
	h.app.openSystemDocument(path)
	h.await("existing system document tab", func() bool { return s.active == standalone })
	if len(s.list) != 2 {
		t.Fatal("reopening a document created another session")
	}
	h.app.openSystemDocument(second)
	h.await("second system document", func() bool { return standalone.project.docs.byPath(second) != nil })
	if len(s.list) != 2 || len(standalone.project.docs.list) != 2 {
		t.Fatal("multiple files did not share the isolated session")
	}
	// Starting a normal project from this window must not inherit the first file.
	s.openTab(beta)
	h.await("new project tab", func() bool { return s.active.project != nil && s.active.project.root == beta })
	if s.active.documentOnly {
		t.Fatal("a normal project inherited standalone mode")
	}
}
