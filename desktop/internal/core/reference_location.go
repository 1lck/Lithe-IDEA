package core

import "context"

// ReferenceLocationRequest is a snapshot of the requested caret and the LSP
// symbols synchronized to that document revision. Coordinates are zero-based
// UTF-16 positions, while the result's human-readable line is one-based.
type ReferenceLocationRequest struct {
	Path        string           `json:"path"`
	Line        int              `json:"line"`
	UTF16Column int              `json:"utf16Column"`
	Symbols     []DocumentSymbol `json:"symbols"`
}

type ReferenceLocationResult struct {
	Reference string `json:"reference"`
	Source    string `json:"source"`
}

// CopyReferenceLocation uses the shared Rust Core formatter. The desktop host
// does not interpret package, type, method names or signature conventions.
func (c *Client) CopyReferenceLocation(ctx context.Context, request ReferenceLocationRequest) (ReferenceLocationResult, error) {
	if request.Symbols == nil {
		request.Symbols = []DocumentSymbol{}
	}
	var result ReferenceLocationResult
	err := c.Execute(ctx, "editor.copyReferenceLocation", request, &result)
	return result, err
}
