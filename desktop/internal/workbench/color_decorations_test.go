package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/gfx"
)

func canvasHasForeground(canvas *gfx.Canvas, color gfx.Color) bool {
	for _, label := range canvas.Texts() {
		for _, run := range canvas.TextRuns(label) {
			if run.Color == color {
				return true
			}
		}
	}
	return false
}

// A valid worker result may already be queued when an edit or provider withdrawal wins the
// next window turn. Reapplying that result must never resurrect its old range positions.
func TestColorDecorationWorkerResultRejectsEditWithdrawalAndClosedDocument(t *testing.T) {
	for _, transition := range []string{"current", "edit", "withdrawal", "replacement", "closed"} {
		t.Run(transition, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			p := &project{ctx: ctx}
			view := editorview.New(editorview.Config{Content: editorview.Prepare([]byte("first second"))})
			t.Cleanup(view.Close)
			d := &document{id: 1, view: view}
			p.docs.list = []*document{d}
			a := &App{project: p}
			request := &documentColorDecorations{cancel: cancel}
			a.editor.colorDecorations.docs = map[int]*documentColorDecorations{1: request}
			revision := view.Revision()
			prepared := editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 5, Light: "#C00050", Dark: "#FF80B0"}})
			switch transition {
			case "edit":
				view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "x"}})
			case "withdrawal":
				a.dropColorDecorations(d)
			case "replacement":
				a.editor.colorDecorations.docs[1] = &documentColorDecorations{cancel: func() {}}
			case "closed":
				p.docs.list = nil
			}
			a.finishColorDecorations(p, d, request, view, revision, prepared, nil)
			canvas := new(gfx.Canvas)
			view.Paint(canvas, gfx.Rect{Width: 600, Height: 200}, editorview.Look{})
			if got := canvasHasForeground(canvas, gfx.RGB24(0xC00050)); got != (transition == "current") {
				t.Fatalf("%s: color result applied=%t", transition, got)
			}
		})
	}
}

func TestMoveOpenDocumentInvalidatesColorDecorations(t *testing.T) {
	root := t.TempDir()
	oldPath, newPath := filepath.Join(root, "sample.src"), filepath.Join(root, "sample.txt")
	if err := os.WriteFile(oldPath, []byte("sample"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, oldPath)
	h.await("document open", func() bool { return p.docs.byPath(oldPath) != nil })
	d := p.docs.byPath(oldPath)
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	request := &documentColorDecorations{cancel: cancel}
	h.app.editor.colorDecorations.docs = map[int]*documentColorDecorations{d.id: request}
	revision := d.view.Revision()
	prepared := editorview.PrepareColorDecorations(d.view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 6, Light: "#C00050", Dark: "#FF80B0"},
	})
	d.view.SetPreparedColorDecorations(prepared)
	if err := os.Rename(oldPath, newPath); err != nil {
		t.Fatal(err)
	}
	h.app.moveOpenDocuments(p, oldPath, newPath)
	if p.docs.byPath(newPath) != d {
		t.Fatal("the same document should stay open at its new path")
	}
	if ctx.Err() != context.Canceled {
		t.Error("the provider request for the old path is still running")
	}
	h.app.finishColorDecorations(p, d, request, d.view, revision, prepared, nil)
	canvas := new(gfx.Canvas)
	d.view.Paint(canvas, gfx.Rect{Width: 600, Height: 200}, editorview.Look{})
	if canvasHasForeground(canvas, gfx.RGB24(0xC00050)) {
		t.Error("the renamed document kept colors selected for its old path")
	}
}
