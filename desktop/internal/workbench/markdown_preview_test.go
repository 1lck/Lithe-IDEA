package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestMarkdownPreviewShowsContentsFromHeadings(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "README.md")
	if err := os.WriteFile(path, []byte("# Title\n\nSome **bold** text.\n\n## Second part\n\nmore\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	h.app.reduceChrome(core.SetChromeOpen(itemMarkdown, true))
	h.settle()
	s := &h.app.editor.markdown
	if len(s.headings) != 2 || s.headings[0].text != "Title" || s.headings[1].level != 2 {
		t.Fatalf("headings = %+v", s.headings)
	}
	if !h.shows("Second part") {
		t.Fatalf("the contents do not list the second heading: %v", h.driver.Snapshot().Labels)
	}
	// An edit is followed.
	doc := p.docs.byPath(path)
	h.app.insertForTest(doc, "\n### Third\n")
	h.settle()
	if len(s.headings) != 3 {
		t.Fatalf("headings after edit = %+v", s.headings)
	}
}

func TestMarkdownPreviewIgnoresOtherFiles(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "main.go")
	if err := os.WriteFile(path, []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	h.app.reduceChrome(core.SetChromeOpen(itemMarkdown, true))
	h.settle()
	if !h.shows("Markdown") || len(h.app.editor.markdown.headings) != 0 || strings.Contains(h.app.editor.markdown.source, "package") {
		t.Fatalf("a Go file was previewed: %+v", h.app.editor.markdown.headings)
	}
}
