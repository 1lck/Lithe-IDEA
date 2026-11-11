package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

func TestMarkdownLinkTargetResolvesExternalRelativeAndAnchor(t *testing.T) {
	document := filepath.Join("work", "README.md")
	if got := markdownLinkTargetOf(document, "https://example.com/a?b=1"); got.external != "https://example.com/a?b=1" || got.path != "" {
		t.Fatalf("external target = %+v", got)
	}
	if got := markdownLinkTargetOf(document, "docs/guide.md#setup"); got.path != filepath.Join("work", "docs", "guide.md") {
		t.Fatalf("relative target = %+v", got)
	}
	if got := markdownLinkTargetOf(document, "#Second-part"); got.anchor != "Second-part" {
		t.Fatalf("anchor target = %+v", got)
	}
	if got := markdownLinkTargetOf(document, "file:///tmp/secret"); got != (markdownLinkTarget{}) {
		t.Fatalf("a non-web scheme resolved to a path: %+v", got)
	}
}

// A relative link in the preview opens the file it points at in the editor.
func TestMarkdownPreviewFollowsRelativeLink(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o700); err != nil {
		t.Fatal(err)
	}
	guide := filepath.Join(root, "docs", "guide.md")
	if err := os.WriteFile(guide, []byte("# Guide\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	readme := filepath.Join(root, "README.md")
	if err := os.WriteFile(readme, []byte("[Guide](docs/guide.md)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, readme)
	h.settle()
	h.app.reduceChrome(core.SetChromeOpen(itemMarkdown, true))
	h.settle()
	d := p.docs.byPath(readme)
	if d == nil {
		t.Fatal("the Markdown file did not open")
	}
	h.app.followMarkdownLink(p, d, "docs/guide.md")
	awaitStateWithin(t, h, 8*time.Second, "the linked file in the editor", func() bool {
		return p.selectedDocument(p.docs.group) != nil && filepath.Clean(p.selectedDocument(p.docs.group).path) == filepath.Clean(guide)
	})
}
