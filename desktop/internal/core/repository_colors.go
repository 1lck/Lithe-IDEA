package core

import "context"

// RepositoryColorRequest contains one page of the full ordered workspace
// repository list, before filtering hidden worktrees. All pages for one view
// must belong to the same list generation.
type RepositoryColorRequest struct {
	Offset        int      `json:"offset"`
	TotalCount    int      `json:"totalCount"`
	RepositoryIDs []string `json:"repositoryIds"`
}

type RepositoryColorAssignment struct {
	ID   string `json:"id"`
	Slot int    `json:"slot"`
}

type RepositoryColors struct {
	Assignments  []RepositoryColorAssignment `json:"assignments"`
	FallbackSlot int                         `json:"fallbackSlot"`
	ShowColors   bool                        `json:"showColors"`
}

// AssignRepositoryColors delegates stable slots to Core; the platform chooses
// only the visual palette. It does not filter or reorder repository identities.
func (c *Client) AssignRepositoryColors(ctx context.Context, request RepositoryColorRequest) (RepositoryColors, error) {
	request.RepositoryIDs = nonNil(request.RepositoryIDs)
	var result RepositoryColors
	err := c.Execute(ctx, "git.repositoryColorAssignments", request, &result)
	return result, err
}
