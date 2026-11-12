package core

import "context"

// NavigationTarget is Core's zero-based line and UTF-16 column. A line-only
// request selects the content of the line instead of placing a caret.
type NavigationTarget struct {
	Line             int  `json:"line"`
	Column           int  `json:"column"`
	SelectsWholeLine bool `json:"selectsWholeLine"`
}

// ParseNavigationInput asks Core to validate and interpret a line:column input.
// A nil target means the input is invalid, not that the operation failed.
func (c *Client) ParseNavigationInput(ctx context.Context, input string) (*NavigationTarget, error) {
	var response struct {
		Target *NavigationTarget `json:"target"`
	}
	err := c.Execute(ctx, "editor.parseNavigationInput", struct {
		Text string `json:"text"`
	}{input}, &response)
	return response.Target, err
}

// DeclarationOrUsages asks Core whether a go-to-declaration gesture made at position in the
// document uri, whose definition answer is definitions, should show the usages of the
// declaration instead (lsp.declarationOrUsages). It is true when every definition is the
// gesture's own place: the caret is already on the declaration, as IntelliJ IDEA's Go to
// Declaration or Usages has it.
func (c *Client) DeclarationOrUsages(ctx context.Context, uri string, position PluginDocumentPosition, definitions []PluginSemanticLocation) (bool, error) {
	type place struct {
		URI   string              `json:"uri"`
		Range PluginDocumentRange `json:"range"`
	}
	places := make([]place, len(definitions))
	for i, definition := range definitions {
		places[i] = place{URI: definition.URI, Range: definition.Range}
	}
	var response struct {
		Action string `json:"action"`
	}
	err := c.Execute(ctx, "lsp.declarationOrUsages", struct {
		URI         string                 `json:"uri"`
		Position    PluginDocumentPosition `json:"position"`
		Definitions []place                `json:"definitions"`
	}{uri, position, places}, &response)
	return response.Action == "usages", err
}
