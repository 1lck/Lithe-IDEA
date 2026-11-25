package workbench

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestWorkflowPreviewIsolationUpdatesAndReadonlyDiff(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root, _ := openNote(t, h, "workspace text")
	w := pluginWorkbench{app: h.app}
	request := pluginservice.PreviewRequest{PluginID: "dev.lithe.test.workflow", Owner: "session:context", ID: "page", Title: "Notes", Text: "# First", Kind: "Markdown", Presentation: "previewOnly"}
	open := func() pluginservice.PreviewResult {
		t.Helper()
		result, err := callOnWindow(h, "preview", func(ctx context.Context) (pluginservice.PreviewResult, error) {
			return w.OpenPreview(ctx, root, request)
		})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	first := open()
	request.Text = "# Updated"
	second := open()
	if !second.WasAlreadyOpen || first.DocumentID != second.DocumentID || !second.IsReadOnly || !second.UsesLiveBuffer || second.Presentation != "previewOnly" {
		t.Fatalf("updated preview=%+v", second)
	}
	var d *document
	for _, candidate := range h.app.project.docs.list {
		if documentPublicID(candidate) == first.DocumentID {
			d = candidate
		}
	}
	if d == nil || !d.virtual || !d.view.ReadOnly() || d.dirty() || d.pageMode != pageOnly {
		t.Fatal("inline preview became editable, dirty, or lost its presentation")
	}
	if text, _ := d.view.Text(); string(text) != request.Text {
		t.Fatalf("preview text=%q", text)
	}
	request.Owner = "another-session:context"
	if third := open(); third.DocumentID == first.DocumentID || third.WasAlreadyOpen {
		t.Fatal("two sessions shared an inline preview")
	}
	before := len(h.app.project.docs.list)
	request.Kind, request.Path = "HTML", filepath.Join(root, "missing.html")
	_, err := callOnWindow(h, "unavailable HTML", func(ctx context.Context) (pluginservice.PreviewResult, error) {
		return w.OpenPreview(ctx, root, request)
	})
	if hostErrorCode(err) != pluginservice.CodeUnsupportedOption || len(h.app.project.docs.list) != before {
		t.Fatalf("unavailable HTML opened a tab: %v", err)
	}
	if err := callOnWindowErr(h, "diff", func(ctx context.Context) error {
		return w.ShowTextDiff(ctx, root, pluginservice.DiffRequest{Title: "note.txt", Original: "before\n", Modified: "after\n"})
	}); err != nil {
		t.Fatal(err)
	}
	h.settleChain()
	diff := h.app.project.diffs.list[0]
	if diff.saved == nil || diff.saved.title != "note.txt" || diff.change.Path != "inline.txt" || !diff.readOnly() {
		t.Fatal("inline diff acquired a working-tree file identity")
	}
}

func TestWorkflowOutputProgressUpdatesAndRelease(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	w := pluginWorkbench{app: h.app}
	for _, update := range []pluginservice.OutputUpdate{
		{ID: "out", Name: "Results", Action: "create"},
		{ID: "out", Action: "append", Lines: []string{"first", "second"}, Open: "tail", MaxLines: 4000, MaxBytes: 512 * 1024},
		{ID: "out", Action: "show"},
	} {
		if err := callOnWindowErr(h, "output", func(ctx context.Context) error { return w.UpdateOutput(ctx, root, update) }); err != nil {
			t.Fatal(err)
		}
	}
	if h.app.project.workflow.selected != "out" || !h.shows("first") {
		t.Fatal("output was not presented")
	}
	if err := callOnWindowErr(h, "clear output", func(ctx context.Context) error {
		return w.UpdateOutput(ctx, root, pluginservice.OutputUpdate{ID: "out", Action: "clear"})
	}); err != nil {
		t.Fatal(err)
	}
	if h.shows("first") || h.shows("tail") {
		t.Fatal("cleared output remained visible")
	}
	percentage := 35.0
	for _, update := range []pluginservice.ProgressUpdate{
		{ID: "progress", Title: "Download", Message: "Reading", MessageSet: true, Percentage: &percentage},
		{ID: "progress", Message: "Finishing", MessageSet: true},
	} {
		if err := callOnWindowErr(h, "progress", func(ctx context.Context) error { return w.UpdateProgress(ctx, root, update) }); err != nil {
			t.Fatal(err)
		}
	}
	item := h.app.project.workflow.progress[0]
	if item.Title != "Download" || item.Message != "Finishing" || item.Percentage == nil || *item.Percentage != 35 {
		t.Fatalf("partial progress update=%+v", item)
	}
	w.ReleaseWorkflow(root, "output", "out")
	w.ReleaseWorkflow(root, "progress", "progress")
	h.settle()
	if state := h.app.project.workflow; len(state.outputs) != 0 || state.selected != "" || len(state.progress) != 0 {
		t.Fatal("workflow UI retained released resources")
	}
}

func TestWorkflowQuickInputAcceptsEmptyAndClearsCancelledPassword(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	w := pluginWorkbench{app: h.app}
	for _, password := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		t.Cleanup(cancel)
		type outcome struct {
			value *pluginservice.QuickResult
			err   error
		}
		done := make(chan outcome, 1)
		go func() {
			value, err := w.QuickInput(ctx, root, pluginservice.QuickInput{Title: "Input", Password: password, Validate: func(context.Context, string) (bool, error) { return true, nil }})
			done <- outcome{value, err}
		}()
		h.await("input ready", func() bool { return len(h.app.prompts.queue) > 0 && h.app.prompts.queue[0].quick.ready })
		state := h.app.prompts.queue[0].quick
		if password {
			state.value = "private value"
			h.app.answerPrompt(nil)
		} else {
			one := 1
			h.app.answerPrompt(&one)
		}
		select {
		case got := <-done:
			if got.err != nil || password && got.value != nil || !password && (got.value == nil || got.value.Value != "") {
				t.Fatalf("input result=%+v, %v", got.value, got.err)
			}
		case <-ctx.Done():
			t.Fatal("input did not finish")
		}
		cancel()
		if state.value != "" || state.request.Value != "" {
			t.Fatal("dismissed input retained a password")
		}
	}
}
