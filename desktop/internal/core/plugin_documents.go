package core

import (
	"context"
	"encoding/json"
)

// PluginDocumentPosition is one position in a document: a zero-based LSP line
// and a zero-based UTF-16 code-unit column.
type PluginDocumentPosition struct {
	Line        int `json:"line"`
	UTF16Column int `json:"utf16Column"`
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
	SessionID         string
	Operation         string
	URI               string
	Position          *PluginDocumentPosition
	CompletionContext json.RawMessage
	// NewName is the rename operation's replacement identifier.
	NewName string
	// Range is the range rangeFormatting formats; Core requires it for that operation.
	Range *PluginDocumentRange
	// FormattingOptions is optional for formatting and rangeFormatting; Core fills unset
	// fields with its defaults.
	FormattingOptions *FormattingOptions
	// OperationID lets the caller register for the answer before the request is
	// sent; Core generates one when empty.
	OperationID string
	// Command is the executeCommand operation's `{command, arguments}` payload.
	Command json.RawMessage
	// Query is the workspaceSymbols operation's search text; the URI is empty for it.
	Query string
}

// FormattingOptions is the LSP FormattingOptions Core accepts on formatting and
// rangeFormatting. TabSize must be 1-1024; a nil boolean keeps Core's default.
type FormattingOptions struct {
	TabSize                int   `json:"tabSize"`
	InsertSpaces           bool  `json:"insertSpaces"`
	TrimTrailingWhitespace *bool `json:"trimTrailingWhitespace,omitempty"`
	InsertFinalNewline     *bool `json:"insertFinalNewline,omitempty"`
	TrimFinalNewlines      *bool `json:"trimFinalNewlines,omitempty"`
}

// PluginDocumentURI asks Core to convert a native absolute path into the
// canonical file URI a session uses. Core owns the platform differences and
// percent-encoding; the host must not spell a file URI itself.
func (c *Client) PluginDocumentURI(ctx context.Context, path, platform string) (string, error) {
	if platform == "" {
		platform = "auto"
	}
	var response struct {
		URI string `json:"uri"`
	}
	if err := c.Execute(ctx, "lsp.documentUri", struct {
		Path     string `json:"path"`
		Platform string `json:"platform"`
	}{path, platform}, &response); err != nil {
		return "", err
	}
	return response.URI, nil
}

// pluginSemanticBody is the lsp.request payload.
type pluginSemanticBody struct {
	SessionID         string                  `json:"sessionId"`
	Operation         string                  `json:"operation"`
	URI               string                  `json:"uri,omitempty"`
	Position          *PluginDocumentPosition `json:"position,omitempty"`
	CompletionContext json.RawMessage         `json:"completionContext,omitempty"`
	NewName           string                  `json:"newName,omitempty"`
	Range             *PluginDocumentRange    `json:"range,omitempty"`
	FormattingOptions *FormattingOptions      `json:"formattingOptions,omitempty"`
	OperationID       string                  `json:"operationId,omitempty"`
	Command           json.RawMessage         `json:"command,omitempty"`
	Query             string                  `json:"query,omitempty"`
}

// RequestPluginSemantics submits a semantic request and returns Core's opaque
// operation ID. Completion and results arrive in the session's ordered events.
func (c *Client) RequestPluginSemantics(ctx context.Context, request PluginSemanticRequest) (string, error) {
	body := pluginSemanticBody{
		SessionID: request.SessionID, Operation: request.Operation, URI: request.URI,
		Position: request.Position, CompletionContext: request.CompletionContext, NewName: request.NewName,
		Range: request.Range, FormattingOptions: request.FormattingOptions,
		OperationID: request.OperationID, Command: request.Command, Query: request.Query,
	}
	var response struct {
		OperationID string `json:"operationId"`
	}
	if err := c.Execute(ctx, "lsp.request", body, &response); err != nil {
		return "", err
	}
	return response.OperationID, nil
}

// PluginDocumentIdentity places a server document in its workspace. Path uses
// native separators; RelativePath is Core's slash-separated display identity.
type PluginDocumentIdentity struct {
	Path         string `json:"path"`
	RelativePath string `json:"relativePath"`
}

// ResolvePluginDocumentIdentity delegates URI parsing and lexical containment to
// Core. A nil document is an expected outside/unsupported identity, not an error.
func (c *Client) ResolvePluginDocumentIdentity(ctx context.Context, root, input, platform string) (*PluginDocumentIdentity, error) {
	var response struct {
		Document *PluginDocumentIdentity `json:"document"`
	}
	err := c.Execute(ctx, "lsp.documentIdentity", struct {
		WorkspaceRoot string `json:"workspaceRoot"`
		Input         string `json:"input"`
		Platform      string `json:"platform"`
	}{root, input, platform}, &response)
	return response.Document, err
}
