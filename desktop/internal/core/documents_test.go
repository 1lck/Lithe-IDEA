package core

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
)

func TestDocumentLifecyclePreservesEditsDuringSave(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	state := DocumentState{Status: DocumentDirty, Revision: 3, SavedRevision: 1}
	started, err := c.ReduceDocument(ctx, state, DocumentEvent{Type: DocumentSaveStarted, OperationID: "save-1"})
	if err != nil || started.Action != DocumentWriteToDisk {
		t.Fatalf("start = %#v, error = %v", started, err)
	}
	change, err := c.ReduceDocument(ctx, started.State, DocumentEvent{Type: DocumentEdited, Revision: 4})
	if err != nil {
		t.Fatal(err)
	}
	stale, err := c.ReduceDocument(ctx, change.State, DocumentEvent{Type: DocumentSaveSucceeded, OperationID: "old-save"})
	if err != nil || stale.Action != DocumentIgnoreStaleResult || stale.State != change.State {
		t.Fatalf("stale completion = %#v, error = %v", stale, err)
	}
	finished, err := c.ReduceDocument(ctx, change.State, DocumentEvent{Type: DocumentSaveSucceeded, OperationID: "save-1"})
	if err != nil || finished.State.Status != DocumentDirty || finished.State.Revision != 4 || finished.State.SavedRevision != 3 {
		t.Fatalf("completion = %#v, error = %v", finished, err)
	}
}

func TestDocumentSaveBatchDetectsChangesDuringSave(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	docs := []SaveBatchDocument{{ID: "one", Dirty: true, ContentSynchronized: true}, {ID: "two", ContentSynchronized: true}}
	plan, err := c.PlanDocumentSaveBatch(ctx, docs)
	if err != nil || !reflect.DeepEqual(plan.Members, []string{"one"}) {
		t.Fatalf("plan = %#v, error = %v", plan, err)
	}
	docs[1].Dirty = true
	result, err := c.ReduceDocumentSaveBatch(ctx, plan.Members, []SaveBatchResult{{ID: "one", Outcome: SaveBatchSaved}}, docs)
	if err != nil || result.Status != SaveBatchIncomplete || !reflect.DeepEqual(result.RemainingDirty, []string{"one", "two"}) {
		t.Fatalf("result = %#v, error = %v", result, err)
	}
}

func TestDocumentStateEncodesRequiredZeroRevisions(t *testing.T) {
	for _, test := range []struct {
		state DocumentState
		want  string
	}{
		{DocumentState{Status: DocumentDirty, Revision: 1}, `{"status":"dirty","revision":1,"savedRevision":0}`},
		{DocumentState{Status: DocumentSaving, Revision: 1, SaveRevision: 1, OperationID: "save"}, `{"status":"saving","revision":1,"savedRevision":0,"saveRevision":1,"operationId":"save"}`},
	} {
		encoded, err := json.Marshal(test.state)
		if err != nil || string(encoded) != test.want {
			t.Fatalf("encoded %s, error %v; want %s", encoded, err, test.want)
		}
	}
}
