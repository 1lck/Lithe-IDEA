package workbench

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

func TestProjectSearchReadsUnsavedTextAndAllSearchesContents(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	h.app.everywhereView.delay = 0
	h.app.settings.DisableAutoSave = true
	root := t.TempDir()
	path := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(path, []byte("old disk text\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	if err := doc.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "unsaved needle\n"}}); err != nil {
		t.Fatal(err)
	}
	h.app.updateProjectSearch(p, searchQuery{text: "needle"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 1 })
	if *p.search.matches[0].Line != 1 {
		t.Fatal(p.search.matches)
	}
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("needle")
	h.settle()
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == 1 })
	if p.everywhere.matches[0].Kind != "content" {
		t.Fatal(p.everywhere.matches)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "old disk text\n" {
		t.Fatalf("search wrote disk: %q %v", data, err)
	}
}

func TestProjectReplacePreservesOriginalEncodingAndRejectsChangedPreview(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := core.NewClient()
	for _, encoding := range []string{"gbk", "utf-16le-bom", "utf-16be-bom", "utf-8-bom", "windows-1252"} {
		t.Run(encoding, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "source.txt")
			text := "needle\r\nnext\r\n"
			if encoding == "gbk" {
				text = "中文 " + text
			}
			if encoding == "windows-1252" {
				text = "café " + text
			}
			before, err := client.EncodeFileText(ctx, text, encoding, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(path, before.Bytes, 0600); err != nil {
				t.Fatal(err)
			}
			preview, err := client.PreviewWorkspaceReplace(ctx, core.WorkspaceReplaceRequest{Root: root, Query: "needle", Replacement: "found", MaxFileBytes: 1 << 20})
			if err != nil || len(preview) != 1 {
				t.Fatalf("preview %+v %v", preview, err)
			}
			outcome := replacePreviewInFile(ctx, client, documentio.WriteGuarded, path, searchQuery{text: "needle"}, "found", 1<<20, preview[0].SourceIdentity)
			if outcome.err != nil || outcome.skipped {
				t.Fatalf("replace %+v", outcome)
			}
			want, err := client.EncodeFileText(ctx, string(bytes.ReplaceAll([]byte(text), []byte("needle"), []byte("found"))), encoding, nil)
			if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, want.Bytes) {
				t.Fatalf("encoding/BOM/CRLF changed: %x %v", got, err)
			}
			if err = os.WriteFile(path, []byte("external needle"), 0600); err != nil {
				t.Fatal(err)
			}
			outcome = replacePreviewInFile(ctx, client, documentio.WriteGuarded, path, searchQuery{text: "needle"}, "found", 1<<20, preview[0].SourceIdentity)
			if !errors.Is(outcome.err, documentio.ErrConflict) {
				t.Fatalf("stale preview wrote: %+v", outcome)
			}
		})
	}
}
