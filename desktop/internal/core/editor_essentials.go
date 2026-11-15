package core

import (
	"context"
	"encoding/json"
	"fmt"
)

// EditorStoredPreferences preserves missing values from earlier settings versions.
// Core alone supplies defaults and validates ranges and style identifiers.
type EditorStoredPreferences struct {
	LineNumbers               *bool   `json:"lineNumbers,omitempty"`
	Whitespace                *bool   `json:"whitespace,omitempty"`
	CursorStyle               string  `json:"cursorStyle,omitempty"`
	CursorBlink               *bool   `json:"cursorBlink,omitempty"`
	AutoSaveDelayMilliseconds *uint64 `json:"autoSaveDelayMilliseconds,omitempty"`
}

// EditorPreferences is the actual presentation configuration resolved by Core.
type EditorPreferences struct {
	LineNumbers                      bool   `json:"lineNumbers"`
	Whitespace                       bool   `json:"whitespace"`
	CursorStyle                      string `json:"cursorStyle"`
	CursorBlink                      bool   `json:"cursorBlink"`
	AutoSaveDelayMilliseconds        uint64 `json:"autoSaveDelayMilliseconds"`
	MinimumAutoSaveDelayMilliseconds uint64 `json:"minimumAutoSaveDelayMilliseconds"`
	MaximumAutoSaveDelayMilliseconds uint64 `json:"maximumAutoSaveDelayMilliseconds"`
}

func (c *Client) ResolveEditorPreferences(ctx context.Context, stored EditorStoredPreferences) (EditorPreferences, error) {
	var result EditorPreferences
	err := c.Execute(ctx, "editor.preferences.resolve", stored, &result)
	return result, err
}

// EditorByteRange is a half-open byte span of the exact immutable snapshot searched.
type EditorByteRange struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

type EditorFindRequest struct {
	Query         string           `json:"query"`
	CaseSensitive bool             `json:"caseSensitive"`
	WholeWord     bool             `json:"wholeWord"`
	Regex         bool             `json:"regex"`
	Range         *EditorByteRange `json:"range,omitempty"`
	Replacement   *string          `json:"replacement,omitempty"`
	ReplaceStart  *int             `json:"replaceStart,omitempty"`
	Caret         int              `json:"caret"`
	Backwards     bool             `json:"backwards"`
}

type EditorReplacement struct {
	EditorByteRange
	Text string `json:"text"`
}

type EditorFindResult struct {
	Range     *EditorByteRange    `json:"range,omitempty"`
	Matches   []EditorByteRange   `json:"matches"`
	Edits     []EditorReplacement `json:"edits"`
	Selected  *int                `json:"selected"`
	Truncated bool                `json:"truncated"`
}

// FindEditorText runs on a worker: source is an immutable snapshot, borrowed by Rust
// rather than copied into a JSON string. Operation cancellation uses the ordinary registry.
func (c *Client) FindEditorText(ctx context.Context, source []byte, input EditorFindRequest) (EditorFindResult, error) {
	var result EditorFindResult
	if err := ctx.Err(); err != nil {
		return result, err
	}
	id := fmt.Sprintf("desktop-%d", nextCoreOperation.Add(1))
	request, err := json.Marshal(requestEnvelope{OperationID: id, Command: "editor.find", Payload: input})
	if err != nil {
		return result, err
	}
	stop := watchCancellation(ctx, id)
	defer stop()
	err = decodeResponse(ctx, "editor.find", executeDocumentJSON(request, source), &result)
	return result, err
}

type EditorRecentEntry struct {
	Path   string `json:"path"`
	Name   string `json:"name"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
	Opened uint64 `json:"opened"`
	Edited uint64 `json:"edited"`
}

type EditorRecentEvent struct {
	Kind   string `json:"kind"`
	Path   string `json:"path"`
	Name   string `json:"name"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

type EditorRecentRequest struct {
	Entries    []EditorRecentEntry `json:"entries,omitempty"`
	Event      *EditorRecentEvent  `json:"event,omitempty"`
	Query      string              `json:"query"`
	OnlyEdited bool                `json:"onlyEdited"`
}

type EditorRecentResult struct {
	Entries []EditorRecentEntry `json:"entries"`
	Results []EditorRecentEntry `json:"results"`
}

func (c *Client) ReduceEditorRecent(ctx context.Context, input EditorRecentRequest) (EditorRecentResult, error) {
	var result EditorRecentResult
	err := c.Execute(ctx, "editor.recent.reduce", input, &result)
	return result, err
}

type EditorRecoveryRequest struct {
	BaseHash  string  `json:"baseHash"`
	DiskHash  *string `json:"diskHash"`
	Scratch   bool    `json:"scratch"`
	Bytes     uint64  `json:"bytes"`
	Saved     bool    `json:"saved"`
	Discarded bool    `json:"discarded"`
}

type EditorRecoveryDecision struct {
	Action           string `json:"action"`
	MaxDocumentBytes int64  `json:"maxDocumentBytes"`
	MaxStorageBytes  int64  `json:"maxStorageBytes"`
	MaxDocuments     int    `json:"maxDocuments"`
}

func (c *Client) DecideEditorRecovery(ctx context.Context, input EditorRecoveryRequest) (EditorRecoveryDecision, error) {
	var result EditorRecoveryDecision
	err := c.Execute(ctx, "editor.recovery.decide", input, &result)
	return result, err
}

type KeymapScheme struct {
	ID       string              `json:"id"`
	Name     string              `json:"name"`
	Bindings map[string][]string `json:"bindings"`
}

type KeymapSchemes struct {
	Active  string         `json:"active"`
	Schemes []KeymapScheme `json:"schemes,omitempty"`
}

type KeymapSchemeRequest struct {
	State     KeymapSchemes       `json:"state"`
	Current   map[string][]string `json:"current,omitempty"`
	Operation string              `json:"operation"`
	ID        string              `json:"id"`
	Name      string              `json:"name"`
	Bindings  map[string][]string `json:"bindings,omitempty"`
}

type KeymapSchemeResult struct {
	State    KeymapSchemes       `json:"state"`
	Bindings map[string][]string `json:"bindings"`
}

func (c *Client) ReduceKeymapSchemes(ctx context.Context, input KeymapSchemeRequest) (KeymapSchemeResult, error) {
	var result KeymapSchemeResult
	err := c.Execute(ctx, "keymap.schemes.reduce", input, &result)
	return result, err
}
