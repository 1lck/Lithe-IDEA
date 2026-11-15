package core

import "context"

// RankCandidate is a host-enumerated name and its optional identity or path.
type RankCandidate struct {
	Name string `json:"name"`
	Path string `json:"path,omitempty"`
}

// RankNames returns indices in Core's matching order. It is for inventories
// the host enumerates, such as a remote catalog, not indexed local workspaces.
func (c *Client) RankNames(ctx context.Context, query string, candidates []RankCandidate) ([]int, error) {
	var result struct {
		Matches []struct {
			Index int `json:"index"`
		} `json:"matches"`
	}
	err := c.Execute(ctx, "workspace.rankNames", struct {
		Query      string          `json:"query"`
		Candidates []RankCandidate `json:"candidates"`
		Limit      int             `json:"limitPerTier"`
	}{query, nonNil(candidates), len(candidates)}, &result)
	if err != nil {
		return nil, err
	}
	indices := make([]int, 0, len(result.Matches))
	for _, match := range result.Matches {
		indices = append(indices, match.Index)
	}
	return indices, nil
}
