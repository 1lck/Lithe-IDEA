package core

import (
	"context"
	"encoding/json"
)

// PluginDocumentPosition is one position in a document: a one-based line and a
// one-based UTF-16 column, which is what the editor contract uses.
type PluginDocumentPosition struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// PluginDocumentRange is a half-open range in a document.
type PluginDocumentRange struct {
	Start PluginDocumentPosition `json:"start"`
	End   PluginDocumentPosition `json:"end"`
}

// PluginTextChange is one LSP content change. A change without a range replaces
// the whole document.
type PluginTextChange struct {
	Range *PluginDocumentRange `json:"range,omitempty"`
	Text  string               `json:"text"`
}

// PluginDocumentSyncRequest opens a document or applies changes to one.
//
// Text and ContentChanges are both optional: sending changes without the full
// text keeps a large document off the wire for every keystroke, and Core replays
// them over the text it holds. Text that disagrees with the replay replaces the
// document instead.
type PluginDocumentSyncRequest struct {
	SessionID      string
	URI            string
	LanguageID     string
	Text           string
	ContentChanges []PluginTextChange
}

// PluginDocumentSync is Core's answer to one synchronization.
type PluginDocumentSync struct {
	// DocumentVersion is the version the session now holds. The first sync opens
	// the document at version 1 and later ones increase it.
	DocumentVersion int64 `json:"documentVersion"`
	// Changed is false when the text was already what the session held; the
	// version is preserved and no notification is sent.
	Changed bool `json:"changed"`
	// URI is the document identity the session resolved, which is what later
	// calls must use.
	URI string `json:"uri"`
}

// SyncPluginDocument opens a document in a session or applies changes to one.
func (c *Client) SyncPluginDocument(ctx context.Context, request PluginDocumentSyncRequest) (PluginDocumentSync, error) {
	body := struct {
		SessionID      string             `json:"sessionId"`
		URI            string             `json:"uri"`
		LanguageID     string             `json:"languageId"`
		Text           string             `json:"text,omitempty"`
		ContentChanges []PluginTextChange `json:"contentChanges,omitempty"`
	}{request.SessionID, request.URI, request.LanguageID, request.Text, request.ContentChanges}
	var response PluginDocumentSync
	if err := c.Execute(ctx, "lsp.syncDocument", body, &response); err != nil {
		return PluginDocumentSync{}, err
	}
	return response, nil
}

// SavePluginDocument reports a confirmed disk save with the exact text that was
// written. sent is false when the session holds no ready document for the URI or
// newer edits superseded the snapshot, which is not an error.
func (c *Client) SavePluginDocument(ctx context.Context, session, uri, text string) (sent bool, err error) {
	var response struct {
		Sent bool `json:"sent"`
	}
	if err := c.Execute(ctx, "lsp.saveDocument", struct {
		SessionID string `json:"sessionId"`
		URI       string `json:"uri"`
		Text      string `json:"text"`
	}{session, uri, text}, &response); err != nil {
		return false, err
	}
	return response.Sent, nil
}

// ClosePluginDocument closes a document in a session and clears its diagnostics.
func (c *Client) ClosePluginDocument(ctx context.Context, session, uri string) error {
	return c.Execute(ctx, "lsp.closeDocument", struct {
		SessionID string `json:"sessionId"`
		URI       string `json:"uri"`
	}{session, uri}, nil)
}

// PluginSemanticRequest is one typed semantic request. Operation is the contract's
// operation name rather than a raw LSP method, so Core decides which server
// feature answers it.
type PluginSemanticRequest struct {
	SessionID       string
	Operation       string
	URI             string
	Position        *PluginDocumentPosition
	DocumentVersion *int64
	Extra           json.RawMessage
}

// RequestPluginSemantics submits a semantic request and returns Core's opaque
// operation ID. Completion and results arrive in the session's ordered events.
func (c *Client) RequestPluginSemantics(ctx context.Context, request PluginSemanticRequest) (string, error) {
	body := struct {
		SessionID       string                  `json:"sessionId"`
		Operation       string                  `json:"operation"`
		URI             string                  `json:"uri,omitempty"`
		Position        *PluginDocumentPosition `json:"position,omitempty"`
		DocumentVersion *int64                  `json:"documentVersion,omitempty"`
		Extra           json.RawMessage         `json:"extra,omitempty"`
	}{request.SessionID, request.Operation, request.URI, request.Position, request.DocumentVersion, request.Extra}
	var response struct {
		OperationID string `json:"operationId"`
	}
	if err := c.Execute(ctx, "lsp.request", body, &response); err != nil {
		return "", err
	}
	return response.OperationID, nil
}
