package core

import "context"

// WorkspaceFindRequest is a bounded plugin search of disk files, without editor snapshots.
type WorkspaceFindRequest struct {
	Root                 string   `json:"root"`
	Query                string   `json:"query,omitempty"`
	Pattern              string   `json:"pattern,omitempty"`
	FileMask             string   `json:"fileMask,omitempty"`
	CaseSensitive        bool     `json:"caseSensitive,omitempty"`
	WholeWords           bool     `json:"wholeWords,omitempty"`
	RegularExpression    bool     `json:"regularExpression,omitempty"`
	Cursor               *string  `json:"cursor,omitempty"`
	Limit                *int     `json:"limit,omitempty"`
	HiddenDirectoryNames []string `json:"hiddenDirectoryNames,omitempty"`
	HiddenFilePatterns   []string `json:"hiddenFilePatterns,omitempty"`
}

// WorkspaceFindMatch is a relative file name or one matched disk line.
// Range is kept as Core's null until the public search owner supplies exact spans.
type WorkspaceFindMatch struct {
	Path    string `json:"path"`
	Line    *int   `json:"line,omitempty"`
	Preview string `json:"preview,omitempty"`
}

// WorkspaceFindPage carries a query-bound continuation and explicit source/omissions.
type WorkspaceFindPage struct {
	Matches     []WorkspaceFindMatch `json:"matches"`
	NextCursor  *string              `json:"nextCursor"`
	IsTruncated bool                 `json:"isTruncated"`
	Source      string               `json:"source"`
}

// FindWorkspaceFiles searches disk file names off the UI thread.
func (c *Client) FindWorkspaceFiles(ctx context.Context, request WorkspaceFindRequest) (WorkspaceFindPage, error) {
	var result WorkspaceFindPage
	err := c.Execute(ctx, "workspace.findFiles", request, &result)
	return result, err
}

// FindWorkspaceText searches disk lines off the UI thread.
func (c *Client) FindWorkspaceText(ctx context.Context, request WorkspaceFindRequest) (WorkspaceFindPage, error) {
	var result WorkspaceFindPage
	err := c.Execute(ctx, "workspace.findText", request, &result)
	return result, err
}

// WorkspaceWatchPlan is Core's validated local scope for a native registration.
type WorkspaceWatchPlan struct {
	Root        string `json:"root"`
	Path        string `json:"path"`
	IsDirectory bool   `json:"isDirectory"`
	Recursive   bool   `json:"recursive"`
}

// PlanWorkspaceWatch rejects invalid, missing and linked scopes before native I/O.
func (c *Client) PlanWorkspaceWatch(ctx context.Context, root, path string, recursive bool) (WorkspaceWatchPlan, error) {
	var plan WorkspaceWatchPlan
	err := c.Execute(ctx, "workspace.watchPlan", struct {
		Root      string `json:"root"`
		Path      string `json:"path"`
		Recursive bool   `json:"recursive"`
	}{root, path, recursive}, &plan)
	return plan, err
}

// WorkspaceWatchEvents are sorted, visible, root-relative names, or a rescan request.
type WorkspaceWatchEvents struct {
	ChangedPaths   []string `json:"changedPaths"`
	RequiresRescan bool     `json:"requiresRescan"`
}

// FilterWorkspaceWatchEvents applies the public watch scope and budgets in Core.
func (c *Client) FilterWorkspaceWatchEvents(ctx context.Context, plan WorkspaceWatchPlan, paths []string, rescan bool) (WorkspaceWatchEvents, error) {
	var result WorkspaceWatchEvents
	err := c.Execute(ctx, "workspace.watchEvents", struct {
		WorkspaceWatchPlan
		Paths          []string `json:"paths"`
		RequiresRescan bool     `json:"requiresRescan"`
	}{plan, nonNil(paths), rescan}, &result)
	return result, err
}
