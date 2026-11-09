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
