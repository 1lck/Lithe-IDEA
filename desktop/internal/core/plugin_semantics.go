package core

import (
	"context"
	"encoding/json"
	"errors"
)

// PluginTextEdit is one edit a completion item applies, in the LSP UTF-16
// coordinates Core normalised. Core validates and applies the range; the host
// never interprets it itself.
type PluginTextEdit struct {
	Range   PluginDocumentRange `json:"range"`
	NewText string              `json:"newText"`
}

// PluginSemanticLocation is one normalised jump target. FilePath is empty for a
// URI that is not a file, such as a class inside a jar; IsReadOnly is true for
// exactly those targets.
type PluginSemanticLocation struct {
	URI         string              `json:"uri"`
	FilePath    string              `json:"filePath"`
	Range       PluginDocumentRange `json:"range"`
	IsReadOnly  bool                `json:"isReadOnly"`
	DisplayPath *string             `json:"displayPath"`
}

// PluginSemanticHover is Core's normalised hover answer. Contents is plain text
// or markdown, which IsMarkdown says; the host presents it as text.
type PluginSemanticHover struct {
	Contents   string               `json:"contents"`
	IsMarkdown bool                 `json:"isMarkdown"`
	Range      *PluginDocumentRange `json:"range"`
}

// PluginSemanticCompletionItem is one normalised completion candidate. Its list
// order and labels are Core's normalised server answer; the host does not
// filter, rank or merge them.
type PluginSemanticCompletionItem struct {
	Label               string           `json:"label"`
	InsertText          string           `json:"insertText"`
	InsertTextFormat    int              `json:"insertTextFormat"`
	Kind                *int             `json:"kind"`
	Detail              string           `json:"detail"`
	Documentation       string           `json:"documentation"`
	SortText            string           `json:"sortText"`
	FilterText          string           `json:"filterText"`
	TextEdit            *PluginTextEdit  `json:"textEdit"`
	AdditionalTextEdits []PluginTextEdit `json:"additionalTextEdits"`
	Data                json.RawMessage  `json:"data"`
	LabelDetails        json.RawMessage  `json:"labelDetails"`
}

// PluginSemanticLocations decodes a completed definition, declaration,
// implementation or reference event.
func PluginSemanticLocations(event BackendEvent) ([]PluginSemanticLocation, error) {
	var payload struct {
		Locations []PluginSemanticLocation `json:"locations"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Locations, nil
}

// PluginDocumentHighlight preserves the upstream Text/Read/Write kind alongside its range.
type PluginDocumentHighlight struct {
	PluginDocumentRange
	Kind *int `json:"kind,omitempty"`
}

// PluginHighlightResult reports whether Core bounded a larger server answer.
type PluginHighlightResult struct {
	Ranges    []PluginDocumentHighlight `json:"ranges"`
	Truncated bool                      `json:"truncated"`
}

func PluginSemanticHighlightRanges(event BackendEvent) (PluginHighlightResult, error) {
	var payload PluginHighlightResult
	err := decodePluginSemanticResult(event, &payload)
	return payload, err
}

// PluginSemanticHoverFromEvent decodes a completed hover event. A nil hover is
// the server's empty answer, not an error.
func PluginSemanticHoverFromEvent(event BackendEvent) (*PluginSemanticHover, error) {
	var payload struct {
		Hover *PluginSemanticHover `json:"hover"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Hover, nil
}

// PluginSemanticCompletions decodes a completed completion event.
func PluginSemanticCompletions(event BackendEvent) ([]PluginSemanticCompletionItem, bool, error) {
	var payload struct {
		Items        []PluginSemanticCompletionItem `json:"items"`
		IsIncomplete bool                           `json:"isIncomplete"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, false, err
	}
	return payload.Items, payload.IsIncomplete, nil
}

func decodePluginSemanticResult(event BackendEvent, target any) error {
	if len(event.Result) == 0 || string(event.Result) == "null" {
		return nil
	}
	if err := json.Unmarshal(event.Result, target); err != nil {
		return errors.New("plugin semantic result is not the normalised shape")
	}
	return nil
}

// ApplyPluginTextEdits validates and applies one batch of LSP text edits to text
// through Core. Core owns the UTF-16 range policy and the order edits apply in;
// the host only supplies the current text and the normalised edits.
func (c *Client) ApplyPluginTextEdits(ctx context.Context, text string, edits []PluginTextEdit) (string, error) {
	var response struct {
		Text string `json:"text"`
	}
	if err := c.Execute(ctx, "lsp.applyTextEdits", struct {
		Text  string           `json:"text"`
		Edits []PluginTextEdit `json:"edits"`
	}{text, edits}, &response); err != nil {
		return "", err
	}
	return response.Text, nil
}

// PlainPluginSnippet removes LSP snippet placeholders through Core, which owns
// the snippet syntax. The host applies only the resulting plain text.
func (c *Client) PlainPluginSnippet(ctx context.Context, value string) (string, error) {
	var response struct {
		Text string `json:"text"`
	}
	if err := c.Execute(ctx, "lsp.plainSnippet", struct {
		Value string `json:"value"`
	}{value}, &response); err != nil {
		return "", err
	}
	return response.Text, nil
}

// PluginSemanticTextEdits decodes a completed formatting event into Core's
// normalised edits. A nil list is the server's empty answer, not an error.
func PluginSemanticTextEdits(event BackendEvent) ([]PluginTextEdit, error) {
	var payload struct {
		Edits []PluginTextEdit `json:"edits"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Edits, nil
}

// PluginSemanticWorkspaceChanges decodes a completed rename event into Core's
// normalised workspace edit: edits keyed by a native file path (or the original
// URI for a target that is not a file). Core projects both `changes` and
// `documentChanges`; file operations are not part of the normalised shape.
func PluginSemanticWorkspaceChanges(event BackendEvent) (map[string][]PluginTextEdit, error) {
	var payload struct {
		Changes map[string][]PluginTextEdit `json:"changes"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Changes, nil
}

// PluginOpenDocument names one open editor document for workspace edit planning.
type PluginOpenDocument struct {
	Path       string `json:"path"`
	IsReadOnly bool   `json:"isReadOnly"`
}

// PluginWorkspaceEditRejection is Core's reason a workspace edit may not be
// applied: outsideWorkspace or readOnlyDocument.
type PluginWorkspaceEditRejection struct {
	Code string `json:"code"`
	Path string `json:"path"`
}

// PluginWorkspaceEditTarget is one file in Core's commit order. Effect is
// writeFile for a closed file and updateDocument for an open editor document.
type PluginWorkspaceEditTarget struct {
	Path         string           `json:"path"`
	RelativePath string           `json:"relativePath"`
	Effect       string           `json:"effect"`
	Edits        []PluginTextEdit `json:"edits"`
}

// PluginWorkspaceEditPlan is Core's validated commit plan.
type PluginWorkspaceEditPlan struct {
	Rejection *PluginWorkspaceEditRejection `json:"rejection"`
	Targets   []PluginWorkspaceEditTarget   `json:"targets"`
}

// PlanPluginWorkspaceEdit validates every target of a workspace edit against the
// workspace and open documents, and orders the commit, through Core.
func (c *Client) PlanPluginWorkspaceEdit(ctx context.Context, workspaceRoot string, changes map[string][]PluginTextEdit, open []PluginOpenDocument) (PluginWorkspaceEditPlan, error) {
	var plan PluginWorkspaceEditPlan
	if open == nil {
		open = []PluginOpenDocument{}
	}
	err := c.Execute(ctx, "lsp.planWorkspaceEdit", struct {
		Platform      string                      `json:"platform"`
		WorkspaceRoot string                      `json:"workspaceRoot"`
		Changes       map[string][]PluginTextEdit `json:"changes"`
		OpenDocuments []PluginOpenDocument        `json:"openDocuments"`
	}{"auto", workspaceRoot, changes, open}, &plan)
	return plan, err
}

// PluginSemanticCommand is a normalised LSP Command attached to a code action.
type PluginSemanticCommand struct {
	Title     string          `json:"title"`
	Command   string          `json:"command"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

// PluginSemanticWorkspaceEdit wraps the normalised file-to-edits map of a code action.
type PluginSemanticWorkspaceEdit struct {
	Changes          map[string][]PluginTextEdit `json:"changes"`
	DocumentVersions map[string]int64            `json:"documentVersions"`
}

// PluginSemanticCodeAction is one Core-normalised, deterministically ordered code action.
type PluginSemanticCodeAction struct {
	Title       string                       `json:"title"`
	Kind        *string                      `json:"kind"`
	Group       string                       `json:"group"`
	IsPreferred bool                         `json:"isPreferred"`
	Edit        *PluginSemanticWorkspaceEdit `json:"edit"`
	Command     *PluginSemanticCommand       `json:"command"`
	Data        json.RawMessage              `json:"data"`
	Raw         json.RawMessage              `json:"-"`
}

// UnmarshalJSON decodes the normalised code action while keeping the raw payload for resolveCodeAction.
func (a *PluginSemanticCodeAction) UnmarshalJSON(data []byte) error {
	type alias PluginSemanticCodeAction
	var decoded alias
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*a = PluginSemanticCodeAction(decoded)
	a.Raw = append(json.RawMessage(nil), data...)
	return nil
}

// PluginSemanticCodeActions decodes a completed codeActions event.
func PluginSemanticCodeActions(event BackendEvent) ([]PluginSemanticCodeAction, error) {
	var payload struct {
		Actions []PluginSemanticCodeAction `json:"actions"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Actions, nil
}

// PluginSemanticResolvedCodeAction decodes a completed resolveCodeAction event.
func PluginSemanticResolvedCodeAction(event BackendEvent) (*PluginSemanticCodeAction, error) {
	var payload struct {
		Action *PluginSemanticCodeAction `json:"action"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Action, nil
}

// PluginSemanticParameterInfo is one parameter of a normalised signature, with both UTF-16 and UTF-8 byte spans.
type PluginSemanticParameterInfo struct {
	Label         string  `json:"label"`
	UTF16Start    *int    `json:"utf16Start"`
	UTF16End      *int    `json:"utf16End"`
	ByteStart     *int    `json:"byteStart"`
	ByteEnd       *int    `json:"byteEnd"`
	Documentation *string `json:"documentation"`
	IsMarkdown    bool    `json:"isMarkdown"`
}

// PluginSemanticSignatureInfo is one overload in a normalised signatureHelp answer.
type PluginSemanticSignatureInfo struct {
	Label           string                        `json:"label"`
	Documentation   *string                       `json:"documentation"`
	IsMarkdown      bool                          `json:"isMarkdown"`
	Parameters      []PluginSemanticParameterInfo `json:"parameters"`
	ActiveParameter *int                          `json:"activeParameter"`
}

// PluginSemanticSignatureHelp is Core's normalised signatureHelp answer.
type PluginSemanticSignatureHelp struct {
	Signatures      []PluginSemanticSignatureInfo `json:"signatures"`
	ActiveSignature int                           `json:"activeSignature"`
	ActiveParameter *int                          `json:"activeParameter"`
	Raw             json.RawMessage               `json:"-"`
}

// UnmarshalJSON decodes the signature help while retaining the normalised JSON for activeSignatureHelp retriggering.
func (s *PluginSemanticSignatureHelp) UnmarshalJSON(data []byte) error {
	type alias PluginSemanticSignatureHelp
	var decoded alias
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*s = PluginSemanticSignatureHelp(decoded)
	s.Raw = append(json.RawMessage(nil), data...)
	return nil
}

// PluginSemanticSignatureHelpFromEvent decodes a completed signatureHelp event.
func PluginSemanticSignatureHelpFromEvent(event BackendEvent) (*PluginSemanticSignatureHelp, error) {
	var payload struct {
		SignatureHelp *PluginSemanticSignatureHelp `json:"signatureHelp"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.SignatureHelp, nil
}

// PluginSemanticInlayHint is one Core-normalised, viewport-culled inlay hint.
type PluginSemanticInlayHint struct {
	Position       PluginDocumentPosition `json:"position"`
	Label          string                 `json:"label"`
	Kind           *int                   `json:"kind"`
	Tooltip        *string                `json:"tooltip"`
	PaddingLeft    bool                   `json:"paddingLeft"`
	PaddingRight   bool                   `json:"paddingRight"`
	TextEdits      []PluginTextEdit       `json:"textEdits"`
	Data           json.RawMessage        `json:"data,omitempty"`
	Raw            json.RawMessage        `json:"-"`
	ResolvePayload json.RawMessage        `json:"resolvePayload,omitempty"`
}

// UnmarshalJSON decodes the hint while keeping the raw JSON for resolveInlayHint.
func (h *PluginSemanticInlayHint) UnmarshalJSON(data []byte) error {
	type alias PluginSemanticInlayHint
	var decoded alias
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*h = PluginSemanticInlayHint(decoded)
	h.Raw = append(json.RawMessage(nil), data...)
	return nil
}

// PluginSemanticInlayHints decodes a completed inlayHints event.
func PluginSemanticInlayHints(event BackendEvent) ([]PluginSemanticInlayHint, error) {
	var payload struct {
		Hints []PluginSemanticInlayHint `json:"hints"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Hints, nil
}

// PluginSemanticResolvedInlayHint decodes a completed resolveInlayHint event.
func PluginSemanticResolvedInlayHint(event BackendEvent) (*PluginSemanticInlayHint, error) {
	var payload struct {
		Hint *PluginSemanticInlayHint `json:"hint"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Hint, nil
}

// PluginWorkspaceApplyEdit is the payload of a server-initiated workspaceApplyEdit event.
type PluginWorkspaceApplyEdit struct {
	ApplyEditID      string                      `json:"applyEditId"`
	Label            *string                     `json:"label"`
	Changes          map[string][]PluginTextEdit `json:"changes"`
	DocumentVersions map[string]int64            `json:"documentVersions"`
}

// PluginWorkspaceApplyEditFromEvent decodes a workspaceApplyEdit runtime event.
func PluginWorkspaceApplyEditFromEvent(event BackendEvent) (PluginWorkspaceApplyEdit, error) {
	var payload PluginWorkspaceApplyEdit
	if len(event.Result) == 0 || string(event.Result) == "null" {
		return payload, errors.New("workspaceApplyEdit event has no result")
	}
	if err := json.Unmarshal(event.Result, &payload); err != nil || payload.ApplyEditID == "" {
		return PluginWorkspaceApplyEdit{}, errors.New("workspaceApplyEdit event is not the normalised shape")
	}
	return payload, nil
}
