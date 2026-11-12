package core

import "context"

// CompletionMergeList is one provider's candidate labels, ordered from the highest-priority
// provider to the lowest. Only labels cross the boundary; the platform applies the returned
// indices to its full items.
type CompletionMergeList struct {
	Labels       []string `json:"labels"`
	IsIncomplete bool     `json:"isIncomplete"`
}

// CompletionMergeResult lists, per input list, the indices that survive, and whether the
// merged list is still incomplete.
type CompletionMergeResult struct {
	Keep         [][]int `json:"keep"`
	IsIncomplete bool    `json:"isIncomplete"`
}

// MergeCompletions asks Core which candidates of several prioritized providers are shown. A
// provider's own candidates are never collapsed; a lower-priority candidate is dropped when a
// higher-priority provider already offered the same label.
func (c *Client) MergeCompletions(ctx context.Context, lists []CompletionMergeList) (CompletionMergeResult, error) {
	var result CompletionMergeResult
	if lists == nil {
		lists = []CompletionMergeList{}
	}
	err := c.Execute(ctx, "lsp.mergeCompletions", struct {
		Lists []CompletionMergeList `json:"lists"`
	}{lists}, &result)
	return result, err
}
