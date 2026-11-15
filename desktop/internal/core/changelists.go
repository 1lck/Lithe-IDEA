package core

import "context"

// ChangeList is one user-named list in Core's validated workspace state.
type ChangeList struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ChangeListState is persisted by the host; Core validates and changes it.
// Assignments are grouped by repository root, not commit repository ID.
type ChangeListState struct {
	Lists       []ChangeList                 `json:"lists"`
	ActiveID    string                       `json:"activeId"`
	Assignments map[string]map[string]string `json:"assignments"`
}

type ChangeListFile struct {
	Root         string `json:"root"`
	Path         string `json:"path"`
	OriginalPath string `json:"originalPath,omitempty"`
	IsCopy       bool   `json:"isCopy"`
}

// ChangeListAction is one documented Core action: create, rename, remove,
// activate, move or rememberRenames. Core decides validity and membership.
type ChangeListAction struct {
	Type string `json:"type"`
	ID   string `json:"id,omitempty"`
	Name string `json:"name,omitempty"`
	// Files is required for move; a pointer preserves an explicit empty array.
	Files *[]ChangeListFile `json:"files,omitempty"`
}

type ChangeListRequest struct {
	State        ChangeListState             `json:"state"`
	Files        []ChangeListFile            `json:"files"`
	Repositories []WorkspaceCommitRepository `json:"repositories"`
	Action       *ChangeListAction           `json:"action,omitempty"`
}

// ChangeListScope is the Core-generated restriction passed unchanged to a
// workspace commit. Paths and membership are keyed by commit repository ID.
type ChangeListScope struct {
	Include    bool                       `json:"include"`
	Paths      map[string][]string        `json:"paths"`
	Membership *ChangeListScopeMembership `json:"membership,omitempty"`
}

type ChangeListScopeMembership struct {
	ActiveID    string                       `json:"activeId"`
	Assignments map[string]map[string]string `json:"assignments"`
}

type ChangeListResult struct {
	State   ChangeListState `json:"state"`
	Members []string        `json:"members"`
	Scope   ChangeListScope `json:"scope"`
}

// ReduceChangeLists delegates list actions, membership and commit scope to
// Core. The caller owns concurrency-safe persistence and stale-result checks.
func (c *Client) ReduceChangeLists(ctx context.Context, request ChangeListRequest) (ChangeListResult, error) {
	request.Files = nonNil(request.Files)
	request.Repositories = nonNil(request.Repositories)
	var result ChangeListResult
	err := c.Execute(ctx, "git.changelists", request, &result)
	return result, err
}
