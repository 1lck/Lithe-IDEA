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
