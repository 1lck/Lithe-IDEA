package core

import "context"

// SearchPresentationRow references a loaded match, or heads its file group.
type SearchPresentationRow struct {
	Path       string `json:"path"`
	Count      int    `json:"count"`
	MatchIndex *int   `json:"matchIndex"`
}

type SearchPresentation struct {
	Rows  []SearchPresentationRow `json:"rows"`
	Files int                     `json:"files"`
	Lines int                     `json:"lines"`
}

func (c *Client) SearchPresentation(ctx context.Context, paths []string, collapsed []string) (SearchPresentation, error) {
	var result SearchPresentation
	err := c.Execute(ctx, "workspace.searchPresentation", struct {
		Paths     []string `json:"paths"`
		Collapsed []string `json:"collapsed"`
	}{nonNil(paths), nonNil(collapsed)}, &result)
	return result, err
}
