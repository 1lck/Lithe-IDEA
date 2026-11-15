package core

import (
	"context"
	"encoding/json"
	"fmt"
)

// DocumentTextKind distinguishes decoded text, binary controls and invalid UTF-8.
type DocumentTextKind int

const (
	DocumentInvalidUTF8 DocumentTextKind = iota
	DocumentBinary
	DocumentPlainText
)

// ClassifyDocumentText uses Core's shared whole-document policy without copying
// the input into JSON. Core borrows data only until this synchronous call ends.
func ClassifyDocumentText(data []byte) (DocumentTextKind, error) {
	switch result := classifyTextBytes(data); result {
	case -1:
		return DocumentInvalidUTF8, nil
	case 0:
		return DocumentBinary, nil
	case 1:
		return DocumentPlainText, nil
	default:
		return DocumentInvalidUTF8, fmt.Errorf("core: unexpected text classification %d", result)
	}
}

// DocumentStatus is the Core persistence state of one open document.
type DocumentStatus string

const (
	DocumentClean    DocumentStatus = "clean"
	DocumentDirty    DocumentStatus = "dirty"
	DocumentSaving   DocumentStatus = "saving"
	DocumentConflict DocumentStatus = "conflict"
)

// DocumentState is a Core persistence snapshot. Revisions belong to the editor;
// operation IDs distinguish completed writes from stale results.
type DocumentState struct {
	Status        DocumentStatus `json:"status"`
	Revision      uint64         `json:"revision"`
	SavedRevision uint64         `json:"savedRevision,omitempty"`
	SaveRevision  uint64         `json:"saveRevision,omitempty"`
	OperationID   string         `json:"operationId,omitempty"`
}

// MarshalJSON preserves required zero-valued revisions in each state variant.
func (s DocumentState) MarshalJSON() ([]byte, error) {
	switch s.Status {
	case DocumentClean:
		return json.Marshal(struct {
			Status   DocumentStatus `json:"status"`
			Revision uint64         `json:"revision"`
		}{s.Status, s.Revision})
	case DocumentDirty, DocumentConflict:
		return json.Marshal(struct {
			Status        DocumentStatus `json:"status"`
			Revision      uint64         `json:"revision"`
			SavedRevision uint64         `json:"savedRevision"`
		}{s.Status, s.Revision, s.SavedRevision})
	case DocumentSaving:
		return json.Marshal(struct {
			Status        DocumentStatus `json:"status"`
			Revision      uint64         `json:"revision"`
			SavedRevision uint64         `json:"savedRevision"`
			SaveRevision  uint64         `json:"saveRevision"`
			OperationID   string         `json:"operationId"`
		}{s.Status, s.Revision, s.SavedRevision, s.SaveRevision, s.OperationID})
	default:
		return json.Marshal(struct {
			Status   DocumentStatus `json:"status"`
			Revision uint64         `json:"revision"`
		}{s.Status, s.Revision})
	}
}

// DocumentEventType identifies an input to the Core document lifecycle reducer.
type DocumentEventType string

const (
	DocumentEdited          DocumentEventType = "edited"
	DocumentSaveStarted     DocumentEventType = "saveStarted"
	DocumentSaveSucceeded   DocumentEventType = "saveSucceeded"
	DocumentSaveFailed      DocumentEventType = "saveFailed"
	DocumentExternalChanged DocumentEventType = "externalChanged"
	DocumentDiskConflict    DocumentEventType = "diskConflict"
	DocumentReloadSucceeded DocumentEventType = "reloadSucceeded"
	DocumentKeepEditor      DocumentEventType = "keepEditor"
	DocumentLoadDisk        DocumentEventType = "loadDisk"
)

// DocumentEvent contains the fields for the selected lifecycle event. Zero revisions
// are encoded for edited/reloaded events rather than omitted.
type DocumentEvent struct {
	Type                DocumentEventType
	Revision            uint64
	MatchesSavedContent bool
	OperationID         string
}

func (e DocumentEvent) payload() any {
	switch e.Type {
	case DocumentEdited:
		return struct {
			Type     DocumentEventType `json:"type"`
			Revision uint64            `json:"revision"`
			Matches  bool              `json:"matchesSavedContent"`
		}{e.Type, e.Revision, e.MatchesSavedContent}
	case DocumentReloadSucceeded:
		return struct {
			Type     DocumentEventType `json:"type"`
			Revision uint64            `json:"revision"`
		}{e.Type, e.Revision}
	case DocumentSaveStarted, DocumentSaveSucceeded, DocumentSaveFailed:
		return struct {
			Type        DocumentEventType `json:"type"`
			OperationID string            `json:"operationId"`
		}{e.Type, e.OperationID}
	default:
		return struct {
			Type DocumentEventType `json:"type"`
		}{e.Type}
	}
}

// DocumentAction is the platform effect selected by Core after a transition.
type DocumentAction string

const (
	DocumentNoAction          DocumentAction = "none"
	DocumentWriteToDisk       DocumentAction = "writeToDisk"
	DocumentReloadFromDisk    DocumentAction = "reloadFromDisk"
	DocumentShowConflict      DocumentAction = "showConflict"
	DocumentReportSaveFailure DocumentAction = "reportSaveFailure"
	DocumentIgnoreStaleResult DocumentAction = "ignoreStaleResult"
)

// DocumentDecision is the next Core state and any I/O or presentation it requests.
type DocumentDecision struct {
	State  DocumentState  `json:"state"`
	Action DocumentAction `json:"action"`
}

// ReduceDocument asks Core to determine a persistence transition.
func (c *Client) ReduceDocument(ctx context.Context, state DocumentState, event DocumentEvent) (DocumentDecision, error) {
	request := struct {
		State DocumentState `json:"state"`
		Event any           `json:"event"`
	}{state, event.payload()}
	var response DocumentDecision
	err := c.Execute(ctx, "document.lifecycle", request, &response)
	return response, err
}

// SaveBatchDocument reports live editor facts used by Core to plan a save batch.
type SaveBatchDocument struct {
	ID                  string `json:"id"`
	Dirty               bool   `json:"dirty"`
	ReadOnly            bool   `json:"readOnly"`
	ContentSynchronized bool   `json:"contentSynchronized"`
}

type SaveBatchPlan struct {
	Members []string `json:"members"`
}
type SaveBatchOutcome string

const (
	SaveBatchSaved      SaveBatchOutcome = "saved"
	SaveBatchFailed     SaveBatchOutcome = "failed"
	SaveBatchCancelled  SaveBatchOutcome = "cancelled"
	SaveBatchIncomplete SaveBatchOutcome = "incomplete"
)

type SaveBatchResult struct {
	ID      string           `json:"id"`
	Outcome SaveBatchOutcome `json:"outcome"`
}
type SaveBatchDecision struct {
	Status         SaveBatchOutcome `json:"status"`
	SavedCount     int              `json:"savedCount"`
	Failed         []string         `json:"failed"`
	Cancelled      []string         `json:"cancelled"`
	RemainingDirty []string         `json:"remainingDirty"`
}

// PlanDocumentSaveBatch lets Core select which open documents need saving.
func (c *Client) PlanDocumentSaveBatch(ctx context.Context, documents []SaveBatchDocument) (SaveBatchPlan, error) {
	request := struct {
		Documents []SaveBatchDocument `json:"documents"`
	}{nonNil(documents)}
	var response SaveBatchPlan
	err := c.Execute(ctx, "document.planSaveBatch", request, &response)
	return response, err
}

// ReduceDocumentSaveBatch checks outcomes against the documents still open after writes.
func (c *Client) ReduceDocumentSaveBatch(ctx context.Context, members []string, results []SaveBatchResult, documents []SaveBatchDocument) (SaveBatchDecision, error) {
	request := struct {
		Members   []string            `json:"members"`
		Results   []SaveBatchResult   `json:"results"`
		Documents []SaveBatchDocument `json:"documents"`
	}{nonNil(members), nonNil(results), nonNil(documents)}
	var response SaveBatchDecision
	err := c.Execute(ctx, "document.reduceSaveBatch", request, &response)
	return response, err
}
