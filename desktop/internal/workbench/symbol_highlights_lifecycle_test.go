package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func TestSymbolHighlightsSurviveUnrelatedServerRelease(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(0, 3)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending.operation != ""
	})
	pending := a.semantics.symbolHighlights.pending

	a.releasePluginDocuments("dev.lithe.test.other-language")
	if a.semantics.symbolHighlights.pending != pending || !a.hasPending(pending) {
		t.Fatal("another language server's release cancelled the current highlight request")
	}
	a.resumeDeferredSemantics()
	if a.semantics.symbolHighlights.pending != pending {
		t.Fatal("unchanged selection submitted a duplicate highlight request")
	}
}

func TestSymbolHighlightsPreserveEarlyResultDuringUnrelatedRelease(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(0, 3)
	a.syncSymbolHighlights(f.p, f.d)
	pending := a.semantics.symbolHighlights.pending
	if pending == nil || pending.operation != "" {
		t.Fatal("expected a highlight request awaiting its operation ID")
	}
	// Hold the UI queue while a response precedes the request's operation binding.
	const operation = "early-highlight"
	a.applyPluginSemanticEvent(f.server, core.BackendEvent{
		Type: pluginSemanticCompleted, OperationID: operation, Method: pluginMethodDocumentHighlight,
		Result: json.RawMessage(`{"ranges":[]}`),
	})
	if len(a.semantics.early) != 1 {
		t.Fatal("the early highlight response was not queued")
	}
	a.releasePluginDocuments("dev.lithe.test.other-language")
	a.semanticRequestStarted(pending, operation, nil, nil)
	if a.hasPending(pending) || a.semantics.symbolHighlights.pending != nil {
		t.Fatal("another language server's release lost the early highlight response")
	}
	f.h.settle()
}

func TestSymbolHighlightsResumeAfterServerResynchronization(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(0, 3)
	a.syncSymbolHighlights(f.p, f.d)
	f.h.await("initial highlight submission", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending.operation != ""
	})
	first := a.semantics.symbolHighlights.pending
	uri := f.d.sync.uri

	a.releasePluginDocuments(f.server.session.PluginID)
	if a.hasPending(first) || a.semantics.symbolHighlights.pending != nil {
		t.Fatal("released server still owns a highlight request")
	}
	// Features can arrive before didOpen completes. Neither event moves the caret.
	a.applyServerFeatures(f.server, core.BackendEvent{Capabilities: []string{pluginSemanticDocumentHighlight}})
	if a.semantics.symbolHighlights.pending != nil {
		t.Fatal("highlight request ran before document synchronization")
	}
	f.deliver(t, first.operation, pluginMethodDocumentHighlight, json.RawMessage(`{"ranges":[]}`))
	f.d.sync.opened, f.d.sync.pluginID, f.d.sync.uri = true, f.server.session.PluginID, uri
	f.d.sync.running, f.d.sync.full, f.d.sync.pending = false, false, nil
	a.resumeDeferredSemantics()
	f.h.await("highlight restored without a caret gesture", func() bool {
		pending := a.semantics.symbolHighlights.pending
		return pending != nil && pending != first && pending.operation != ""
	})
	if got := f.kernel.request(f.kernel.requestCount() - 1); got.Operation != pluginSemanticDocumentHighlight || got.URI != uri {
		t.Fatalf("restored request = %+v", got)
	}
}

func TestSymbolHighlightsForgetDocumentAfterAllServersRelease(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.semantics.symbolHighlightDelay = -1
	f.server.features = map[string]bool{pluginSemanticDocumentHighlight: true}
	f.d.view.SetSelection(0, 3)
	a.syncSymbolHighlights(f.p, f.d)
	a.releaseAllPluginDocuments()
	a.resumeDeferredSemantics()
	state := &a.semantics.symbolHighlights
	if state.key.document != nil || state.pending != nil || state.timer != nil || state.cancel != nil {
		t.Fatal("project teardown retained a highlight target or scheduled new work")
	}
}

func TestSymbolHighlightsRestoreWhenReturningToDocument(t *testing.T) {
	h, first, kernel := openHighlightGestureDocument(t, "first.ts", "name = name\n", false)
	a, p := h.app, h.app.project
	otherPath := filepath.Join(filepath.Dir(first.path), "other.ts")
	if err := os.WriteFile(otherPath, []byte("other = other\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	first.view.SetSelection(0, len("name"))
	a.syncSymbolHighlights(p, first)
	requireHighlightGestureQuery(t, h, kernel, "name")
	h.settle()

	a.openFile(p, otherPath)
	h.await("other document opened", func() bool { return p.docs.byPath(otherPath) != nil })
	h.settle()
	if a.semantics.symbolHighlights.key.document == first {
		t.Fatal("the inactive document still owns the highlights")
	}
	a.selectDocument(p, first.id)
	h.settle()
	if start, end := first.view.Selection(); start != 0 || end != len("name") {
		t.Fatalf("returning changed the selection to %d..%d", start, end)
	}
	requireHighlightGestureQuery(t, h, kernel, "name")
	h.settle()
	if a.semantics.symbolHighlights.key.document != first {
		t.Fatal("returning did not restore highlights for the preserved selection")
	}
	// Repaints and a repeated activation must not restart the same request.
	a.selectDocument(p, first.id)
	h.settle()
	if len(kernel.requests) != 0 {
		t.Fatal("unchanged activation repeated the highlight query")
	}
}

func TestSymbolHighlightsDoNotRetainVimClosedDocument(t *testing.T) {
	h, d, _ := openHighlightGestureDocument(t, "example.ts", "name = name\n", true)
	p := h.app.project
	if err := h.driver.Type(":q!"); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if p.docs.find(d.id) != nil {
		t.Fatal("Vim did not close the document")
	}
	state := &h.app.semantics.symbolHighlights
	if state.key.document != nil || state.pending != nil || state.timer != nil || state.cancel != nil {
		t.Fatal("Vim close left symbol-highlight work or retained the closed document")
	}
}
