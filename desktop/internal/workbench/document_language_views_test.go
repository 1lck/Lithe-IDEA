package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

func TestKnownPathOpensWhilePluginLanguagesLoad(t *testing.T) {
	var a App
	load := &languageLoad{done: make(chan struct{})}
	defer close(load.done)
	a.initialLanguageLoad.Store(load)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	language, grammar := a.resolveDocumentLanguage(ctx, syntax.NewRegistry(), "Makefile", rope.New([]byte("all:\n")))
	if language != "makefile" || grammar == nil {
		t.Fatalf("language = %q, grammar = %v, want Makefile syntax without waiting for plugins", language, grammar)
	}
}

func newFirstLineViewHarness(t *testing.T) *harness {
	t.Helper()
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	registerFirstLineViewSyntax(t, h)
	return h
}

func registerFirstLineViewSyntax(t *testing.T, h *harness) {
	t.Helper()
	failed, _ := h.app.syntaxRegistry().SetPluginLanguages([]syntax.PluginLanguage{{
		ID: "sample", FirstLineMatch: "^#! */opt/tools/sample$",
		Grammar: []byte(`{"scopeName":"source.sample","patterns":[{"match":"sample","name":"keyword.control.sample"}]}`),
	}})
	if len(failed) != 0 {
		t.Fatal(failed)
	}
}

func writeFirstLineViewFile(t *testing.T, root string) string {
	t.Helper()
	path := filepath.Join(root, "script")
	if err := os.WriteFile(path, []byte("#!/opt/tools/sample\nsample\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func requireFirstLineViewHighlight(t *testing.T, view *editorview.View, line int) {
	t.Helper()
	tokens := view.SyntaxLine(nil, line)
	for _, token := range tokens {
		if strings.HasPrefix(token.Name.String(), "keyword") {
			return
		}
	}
	t.Fatalf("sample keyword has no syntax highlighting: %v", tokens)
}

func TestDiffWorkingCopyUsesFirstLineSyntax(t *testing.T) {
	root := newTestRepository(t)
	path := writeFirstLineViewFile(t, root)
	h := newFirstLineViewHarness(t)
	p := h.openCommit(root)
	tab := openDiffTab(t, h, p, filepath.Base(path))
	doc := p.docs.byPath(path)
	if doc == nil || !doc.tabless || doc.languageID != "sample" {
		t.Fatal("Diff did not open a tabless sample document")
	}
	if tab.after == nil || tab.after.view.ReadOnly() {
		t.Fatal("the working copy is not editable")
	}
	requireFirstLineViewHighlight(t, doc.view, 1)
	requireFirstLineViewHighlight(t, tab.after.view, 1)
}

func TestSourcePreviewKeepsOpenDocumentsFirstLineSyntax(t *testing.T) {
	root := t.TempDir()
	path := writeFirstLineViewFile(t, root)
	h := newFirstLineViewHarness(t)
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.await("the extensionless file to open", func() bool { return p.docs.byPath(path) != nil })
	doc := p.docs.byPath(path)
	if doc.languageID != "sample" {
		t.Fatalf("language = %q, want sample", doc.languageID)
	}
	if !doc.view.ApplyEdit(editorview.Edit{StartLine: 0, EndLine: 1, Text: "ordinary text\n"}, true) {
		t.Fatal("could not replace the first line")
	}
	requireFirstLineViewHighlight(t, doc.view, 1)

	var preview sourcePreview
	defer preview.close()
	h.app.showSourcePreview(p, &preview, path, 2, func(*App) bool { return true })
	h.await("the read-only preview to open", func() bool { return preview.view != nil })
	requireFirstLineViewHighlight(t, preview.view, 1)
}
