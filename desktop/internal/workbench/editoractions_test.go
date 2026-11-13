package workbench

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestEditorActionBindingRefreshDropsEarlierCollectionAtSameTextVersion(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"source.txt": "content\n"})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, filepath.Join(root, "source.txt"))
	h.settle()
	d := documentNamed(p, "source.txt")
	if d == nil {
		t.Fatal("source document unavailable")
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger

	// The model, rather than the text, changed while an earlier collection
	// was in flight. Deliver the latest result first and the earlier empty
	// result/error last, with no clock or subprocess race in this regression.
	h.app.clearEditorActions(d)
	old := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
	h.app.clearEditorActions(d)
	current := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
	want := []pluginservice.EditorAction{{ID: "latest", Title: "Latest", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 1}}}
	h.app.presentEditorActions(p, current, want, nil, nil)
	h.app.presentEditorActions(p, old, nil, nil, errors.New("earlier collection failed"))
	if len(d.actions) != 1 || d.actions[0].ID != "latest" {
		t.Fatalf("earlier collection replaced current actions: %+v", d.actions)
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	for _, event := range logger.events {
		if event.Event == operationFailedEvent && event.Fields["operation"] == "editor_actions" {
			t.Fatal("earlier collection replaced current failure presentation")
		}
	}
}
