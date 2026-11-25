package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

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

// viewHasForeground reports whether a painted frame of view draws text in color.
func viewHasForeground(view *editorview.View, color uint32) bool {
	canvas := new(gfx.Canvas)
	view.Paint(canvas, gfx.Rect{Width: 600, Height: 200}, editorview.Look{})
	return canvasHasForeground(canvas, gfx.RGB24(color))
}

// Typing must not make a rainbow flicker: the colors the view moved with the edit stay while the
// pause before the next request restarts, the edit looks no provider up again, and only the
// answer of the latest request replaces them. A change of the color providers looks them up again
// at once and drops what an unserved document showed. The pause is an hour, so the timer is only
// ever stopped, never fired, and the test never waits on the clock.
func TestColorDecorationEditKeepsMovedColorsUntilLatestAnswer(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	p := &project{ctx: ctx}
	view := editorview.New(editorview.Config{Content: editorview.Prepare([]byte("(a) [b]"))})
	t.Cleanup(view.Close)
	d := &document{id: 1, path: "/work/sample.src", languageID: "sample", view: view}
	p.docs.list = []*document{d}
	a := &App{project: p}
	// The providers were looked up when the document opened. No plugin service is attached, so a
	// second lookup would find no provider and clear the colors.
	state := &documentColorDecorations{path: d.path, language: d.languageID, known: true, provided: true}
	a.editor.colorDecorations.docs = map[int]*documentColorDecorations{d.id: state}
	t.Cleanup(func() { a.dropColorDecorations(d) })
	view.SetPreparedColorDecorations(editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 1, Light: "#C00050", Dark: "#C00050"},
	}))

	view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "x"}})
	a.scheduleColorDecorations(p, d, time.Hour)
	first, stale := state.timer, state.generation
	if first == nil || !state.provided {
		t.Fatalf("the edit should restart the pause from the cached lookup: timer %v, provided %t", first, state.provided)
	}
	if !viewHasForeground(view, 0xC00050) {
		t.Fatal("the edit cleared the colors it should have moved")
	}
	a.scheduleColorDecorations(p, d, time.Hour)
	if first.Stop() {
		t.Fatal("the next keystroke left the earlier pause running")
	}
	answer := editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 1, EndLine: 0, EndCharacter: 2, Light: "#0050C0", Dark: "#0050C0"},
	})
	a.finishColorDecorations(p, d, state, stale, view, view.Revision(), answer, nil)
	if viewHasForeground(view, 0x0050C0) || !viewHasForeground(view, 0xC00050) {
		t.Fatal("an answer to an overtaken request replaced the colors")
	}
	a.finishColorDecorations(p, d, state, state.generation, view, view.Revision(), answer, nil)
	if !viewHasForeground(view, 0x0050C0) || viewHasForeground(view, 0xC00050) {
		t.Fatal("the latest answer did not replace the moved colors")
	}

	a.colorProvidersChanged(p)
	if !state.known || state.provided || state.timer != nil || viewHasForeground(view, 0x0050C0) {
		t.Fatalf("a provider change should look the providers up again and clear an unserved document: known %t, provided %t", state.known, state.provided)
	}
}

// A valid worker result may already be queued when an edit or provider withdrawal wins the
// next window turn. Reapplying that result must never resurrect its old range positions.
func TestColorDecorationWorkerResultRejectsEditWithdrawalAndClosedDocument(t *testing.T) {
	for _, transition := range []string{"current", "edit", "overtaken", "withdrawal", "replacement", "closed"} {
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
			generation, revision := request.generation, view.Revision()
			prepared := editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 5, Light: "#C00050", Dark: "#FF80B0"}})
			switch transition {
			case "edit":
				view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "x"}})
			case "overtaken":
				request.revoke()
			case "withdrawal":
				a.dropColorDecorations(d)
			case "replacement":
				a.editor.colorDecorations.docs[1] = &documentColorDecorations{cancel: func() {}}
			case "closed":
				p.docs.list = nil
			}
			a.finishColorDecorations(p, d, request, generation, view, revision, prepared, nil)
			if got := viewHasForeground(view, 0xC00050); got != (transition == "current") {
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
	generation, revision := request.generation, d.view.Revision()
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
	h.app.finishColorDecorations(p, d, request, generation, d.view, revision, prepared, nil)
	if viewHasForeground(d.view, 0xC00050) {
		t.Error("the renamed document kept colors selected for its old path")
	}
}
