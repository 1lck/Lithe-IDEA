package core

import "context"

// ProblemsSeverityCounts is how many diagnostics a Problems query selected or
// found for each LSP severity. Unknown covers a missing or out-of-range severity.
type ProblemsSeverityCounts struct {
	Error       int `json:"error"`
	Warning     int `json:"warning"`
	Information int `json:"information"`
	Hint        int `json:"hint"`
	Unknown     int `json:"unknown"`
}

// ProblemsDiagnostic is the part of one displayed diagnostic that affects
// filtering and order. Message, Source and Code are carried so Core can filter
// on them; the platform keeps the item it will open and render.
type ProblemsDiagnostic struct {
	// FileKey is the platform's absolute document identity. The host keeps it so
	// a query result's indices stay usable without a second copy of the item.
	FileKey string `json:"fileKey"`
	// DisplayPath is the workspace-relative path the user sees, which decides
	// file order with the Project view's natural file-name order.
	DisplayPath string `json:"displayPath"`
	// Line is zero-based; Column counts UTF-16 code units, as LSP does.
	Line   int `json:"line"`
	Column int `json:"column"`
	// Severity is the LSP number 1-4; 0 is an unknown or omitted severity, which
	// Core ranks after hints.
	Severity int    `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source,omitempty"`
	Code     string `json:"code,omitempty"`
}

// ProblemsFilter narrows the diagnostics a Problems query shows. A zero value
// keeps everything.
type ProblemsFilter struct {
	// Severities keeps only these LSP severities; 0 selects unknown severities.
	Severities []int `json:"severities,omitempty"`
	// FileKey restricts the result to one document, for "current file only".
	FileKey string `json:"fileKey,omitempty"`
	// Source matches the diagnostic source case-insensitively.
	Source string `json:"source,omitempty"`
	// Query is a case-insensitive substring over message, source, code, path and
	// the one-based line:column label.
	Query string `json:"query,omitempty"`
}

// GroupBy values accepted by lsp.problems.query.
const (
	ProblemsGroupByFile     = "file"
	ProblemsGroupBySeverity = "severity"
	ProblemsGroupByNone     = "none"
)

// SortBy values accepted by lsp.problems.query.
const (
	ProblemsSortBySeverity = "severity"
	ProblemsSortByFile     = "file"
	ProblemsSortByPosition = "position"
)

// ProblemsQuery is one Problems tool-window query. The empty GroupBy and SortBy
// ask for Core's defaults: group by file, sort by severity. Collapsed and Selected
// are the tree state the window keeps: the keys of the group nodes the user
// closed and the selected row's key.
type ProblemsQuery struct {
	Diagnostics []ProblemsDiagnostic `json:"diagnostics"`
	GroupBy     string               `json:"groupBy,omitempty"`
	SortBy      string               `json:"sortBy,omitempty"`
	Filter      *ProblemsFilter      `json:"filter,omitempty"`
	Collapsed   []string             `json:"collapsed,omitempty"`
	Selected    string               `json:"selected,omitempty"`
}

// ProblemsGroup is one group of a Problems query result. Indices point into the
// diagnostics that were submitted with the query, in display order.
type ProblemsGroup struct {
	// Key is stable across equal input: file:<fileKey>, severity:<n>, or all.
	Key string `json:"key"`
	// Kind is file, severity or all.
	Kind        string `json:"kind"`
	FileKey     string `json:"fileKey,omitempty"`
	DisplayPath string `json:"displayPath,omitempty"`
	// Name and Folder are a file group's DisplayPath split at its last segment;
	// Folder is empty at the workspace root.
	Name   string `json:"name,omitempty"`
	Folder string `json:"folder,omitempty"`
	// Severity is the group's LSP severity for a severity group; 0 is the
	// unknown-severity group.
	Severity int                    `json:"severity,omitempty"`
	Indices  []int                  `json:"indices"`
	Counts   ProblemsSeverityCounts `json:"counts"`
}

// ProblemsFile is one file's visible diagnostics in file order, independent of
// how the groups are formed.
type ProblemsFile struct {
	FileKey         string                 `json:"fileKey"`
	DisplayPath     string                 `json:"displayPath"`
	Count           int                    `json:"count"`
	HighestSeverity int                    `json:"highestSeverity"`
	Counts          ProblemsSeverityCounts `json:"counts"`
}

// The kinds of a Problems row.
const (
	ProblemsRowGroup      = "group"
	ProblemsRowDiagnostic = "diagnostic"
)

// ProblemsRow is a row of the Problems tree that shows.
type ProblemsRow struct {
	// Key stays the row's while nodes open and close, and a diagnostic's key
	// stays its own when the server republishes the list in another order.
	Key   string `json:"key"`
	Kind  string `json:"kind"`
	Depth int    `json:"depth"`
	// Expanded is whether a node's diagnostics show; nil on a diagnostic.
	Expanded *bool `json:"expanded,omitempty"`
	// Group is the row's group.
	Group int `json:"group"`
	// Shows is the diagnostic the row previews and opens: itself or a node's first.
	Shows int `json:"shows"`
}

// ProblemsResult is Core's filtered, ordered and grouped Problems list and the
// tree rows that show it.
type ProblemsResult struct {
	Groups        []ProblemsGroup        `json:"groups"`
	Files         []ProblemsFile         `json:"files"`
	VisibleCounts ProblemsSeverityCounts `json:"visibleCounts"`
	TotalCounts   ProblemsSeverityCounts `json:"totalCounts"`
	Rows          []ProblemsRow          `json:"rows"`
	// Selected is the selected row's key, always one of Rows, and SelectedRow its
	// place; both are absent when nothing is selected.
	Selected    string `json:"selected,omitempty"`
	SelectedRow *int   `json:"selectedRow,omitempty"`
}

// QueryProblems asks Core to filter, order and group the displayed diagnostics.
//
// The diagnostics are the only copy of the item text that crosses the boundary;
// Core answers with indices into that list, so the platform never receives the
// message payload twice. Core is pure here: the call does no I/O and starts no
// process.
func (c *Client) QueryProblems(ctx context.Context, request ProblemsQuery) (ProblemsResult, error) {
	request.Diagnostics = nonNil(request.Diagnostics)
	var result ProblemsResult
	if err := c.Execute(ctx, "lsp.problems.query", request, &result); err != nil {
		return ProblemsResult{}, err
	}
	return result, nil
}
