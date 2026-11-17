package core

import "context"

// ReferenceLocation is one location of a Find Usages answer as Core groups it.
type ReferenceLocation struct {
	// FileKey is the file's identity under the platform's path equality: the path of a local
	// file, or the URI of a location that is not one.
	FileKey string `json:"fileKey"`
	// DisplayPath is the path shown to the user, with / separators, relative to the project for
	// a file in it. It decides the file order.
	DisplayPath string `json:"displayPath"`
	// Line and Column are the zero-based start, the column in UTF-16 units.
	Line   int `json:"line"`
	Column int `json:"column"`
}

// ReferencesQuery asks Core to lay the References tool window out: the locations, the file
// nodes the user closed (by FileKey), whether the Usages node is closed, and the selected key.
type ReferencesQuery struct {
	Locations     []ReferenceLocation `json:"locations"`
	RootCollapsed bool                `json:"rootCollapsed,omitempty"`
	Collapsed     []string            `json:"collapsed,omitempty"`
	Selected      string              `json:"selected,omitempty"`
}

// ReferenceGroup is the usages in one file.
type ReferenceGroup struct {
	// Key is the key of the file's row.
	Key         string `json:"key"`
	FileKey     string `json:"fileKey"`
	DisplayPath string `json:"displayPath"`
	// Name and Folder are DisplayPath's last segment and the rest; Folder is empty at the root.
	Name   string `json:"name"`
	Folder string `json:"folder"`
	// Indices point into the query's locations, in display order.
	Indices []int `json:"indices"`
}

// The kinds of a References row.
const (
	ReferenceRowRoot  = "root"
	ReferenceRowFile  = "file"
	ReferenceRowUsage = "usage"
)

// ReferenceRow is a row of the References tree that shows.
type ReferenceRow struct {
	// Key stays the row's while the nodes above it open and close.
	Key   string `json:"key"`
	Kind  string `json:"kind"`
	Depth int    `json:"depth"`
	// Expanded is whether a node's children show; nil on a usage.
	Expanded *bool `json:"expanded,omitempty"`
	// Group is the group of a file or usage row.
	Group *int `json:"group,omitempty"`
	// Shows is the location the row previews and opens: the usage itself or a node's first.
	Shows int `json:"shows"`
	// Previous and Next are the usages before and after the row in the tree's order, counting
	// the usages under closed nodes; nil at either end.
	Previous *int `json:"previous,omitempty"`
	Next     *int `json:"next,omitempty"`
}

// ReferencesResult is the References tree Core laid out.
type ReferencesResult struct {
	Groups []ReferenceGroup `json:"groups"`
	Rows   []ReferenceRow   `json:"rows"`
	// Selected is the selected row's key, always one of Rows, and SelectedRow its place; both
	// are absent when Rows is empty.
	Selected    string `json:"selected,omitempty"`
	SelectedRow *int   `json:"selectedRow,omitempty"`
}

// ReferenceUsageLine is a usage and the text of the line it starts on, by index.
type ReferenceUsageLine struct {
	Text      int `json:"text"`
	Line      int `json:"line"`
	Column    int `json:"column"`
	EndLine   int `json:"endLine"`
	EndColumn int `json:"endColumn"`
}

// ReferenceLinesRequest is the distinct texts of the usages' lines and the usages on them.
type ReferenceLinesRequest struct {
	Texts  []string             `json:"texts"`
	Usages []ReferenceUsageLine `json:"usages"`
}

// ReferenceLine is a usage's line as its row shows it, the usage's UTF-16 range in it.
type ReferenceLine struct {
	Text   string            `json:"text"`
	Ranges []SearchNameRange `json:"ranges"`
}

// QueryReferences groups a Find Usages answer by file and lays its rows out.
func (c *Client) QueryReferences(ctx context.Context, request ReferencesQuery) (ReferencesResult, error) {
	request.Locations = nonNil(request.Locations)
	var result ReferencesResult
	if err := c.Execute(ctx, "lsp.references.query", request, &result); err != nil {
		return ReferencesResult{}, err
	}
	return result, nil
}

// ReferenceLines shows the usages' lines, one per usage in order.
func (c *Client) ReferenceLines(ctx context.Context, request ReferenceLinesRequest) ([]ReferenceLine, error) {
	request.Texts, request.Usages = nonNil(request.Texts), nonNil(request.Usages)
	var result struct {
		Lines []ReferenceLine `json:"lines"`
	}
	if err := c.Execute(ctx, "lsp.references.lines", request, &result); err != nil {
		return nil, err
	}
	return result.Lines, nil
}
