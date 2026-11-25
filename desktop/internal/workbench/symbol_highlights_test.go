package workbench

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

func TestSymbolHighlightsUseDocumentHighlightAndDiscardOldAnswer(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(3, 0)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending.operation != ""
	})
	first := a.semantics.symbolHighlights.pending
	req := f.kernel.request(0)
	if req.Operation != pluginSemanticDocumentHighlight || req.URI != f.d.sync.uri || req.Position == nil || *req.Position != (core.PluginDocumentPosition{}) {
		t.Fatalf("selection did not ask for document highlights at its start: %#v", req)
	}

	f.d.view.SetSelection(2, 2)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("new caret highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending != first && pending.operation != ""
	})
	second := a.semantics.symbolHighlights.pending
	if a.hasPending(first) {
		t.Fatal("old caret is still registered for highlights")
	}
	result := json.RawMessage(`{"ranges":[{"start":{"line":0,"utf16Column":0},"end":{"line":0,"utf16Column":3}}]}`)
	f.deliver(t, first.operation, pluginMethodDocumentHighlight, result)
	if a.semantics.symbolHighlights.pending != second {
		t.Fatal("old caret's answer settled the new request")
	}
	f.deliver(t, second.operation, pluginMethodDocumentHighlight, result)
	f.h.await("current highlight ranges projected into the document", func() bool {
		s := &a.semantics.symbolHighlights
		return s.pending == nil && s.cancel == nil
	})
}

func TestSelectedWordHighlightsUseCoreWholeWordMatching(t *testing.T) {
	const source = "😀 task other_task Task task tasking"
	start := strings.Index(source, "task")
	end := start + len("task")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result, err := core.NewClient().FindEditorText(ctx, []byte(source), core.EditorFindRequest{
		Query: "task", CaseSensitive: true, WholeWord: true, Caret: start,
	})
	if err != nil {
		t.Fatal(err)
	}
	second := strings.Index(source, "task tasking")
	want := []editorview.Range{{Start: second, End: second + len("task")}}
	if got := selectedWordHighlights(result.Matches, start, end); !slices.Equal(got, want) {
		t.Fatalf("whole-word ranges = %+v, want %+v", got, want)
	}
	partial := strings.Index(source, "tasking")
	if got := selectedWordHighlights(result.Matches, partial, partial+len("task")); len(got) != 0 {
		t.Fatalf("partial identifier selection displayed %v", got)
	}
}
