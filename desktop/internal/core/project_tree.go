package core

import (
	"context"
	"encoding/json"
)

// RowSelection is the multi-selection of rows that show workspace paths, such as the project
// tree and the changes of a change list. The empty path is the workspace root, which is never
// marked.
type RowSelection struct {
	// Selected is the path of the selected row, nil when no row is selected.
	Selected *string `json:"selected"`
	// Marked are the paths marked for a batch, in path order.
	Marked []string `json:"marked,omitempty"`
	// Anchor is the path a Shift click extends from, empty when there is none.
	Anchor string `json:"anchor,omitempty"`
}

// RowAction is one click on a row, or the end of a batch. Build it with ChooseRow, ToggleRow,
// ExtendRow or ClearRows.
type RowAction struct {
	kind, path string
}

// ChooseRow is a plain click on the row of path: it selects the row and drops the marks and the
// anchor.
func ChooseRow(path string) RowAction { return RowAction{kind: "choose", path: path} }

// ToggleRow is a Cmd or Ctrl click on the row of path: it marks or unmarks the row, selects it
// and makes it the anchor.
func ToggleRow(path string) RowAction { return RowAction{kind: "toggle", path: path} }

// ExtendRow is a Shift click on the row of path: it marks every row from the anchor, else from
// the selected row, to this one, keeps the other marks and selects the row.
func ExtendRow(path string) RowAction { return RowAction{kind: "extend", path: path} }

// ClearRows ends a batch: the marks and the anchor go and the selected row stays.
func ClearRows() RowAction { return RowAction{kind: "clear"} }

// MarshalJSON encodes the action as the exact object of its kind.
func (a RowAction) MarshalJSON() ([]byte, error) {
	if a.kind == "clear" || a.kind == "" {
		return json.Marshal(struct {
			Kind string `json:"kind"`
		}{"clear"})
	}
	return json.Marshal(struct {
		Kind string `json:"kind"`
		Path string `json:"path"`
	}{a.kind, a.path})
}

// RowSelectionStale is the rejection of a click on a path that is not one of the rows, as when
// the row went away between the paint that showed it and the click.
const RowSelectionStale = "workspace.rowSelection.stale"

// RowSelectionResult is the outcome of one workspace.rowSelection.reduce.
type RowSelectionResult struct {
	Selection RowSelection `json:"selection"`
	// Targets is what a batch acts on: the marked paths without those inside a marked folder,
	// empty when nothing is marked.
	Targets []string `json:"targets"`
	// Rejection says why the action did not apply; Selection is then as sent.
	Rejection string `json:"rejection"`
}

// ReduceRowSelection applies action to selection over rows, the paths of the rows the host
// shows, top to bottom (workspace.rowSelection.reduce). The call only computes over its
// arguments and is fast enough for an event handler.
func (c *Client) ReduceRowSelection(ctx context.Context, rows []string, selection RowSelection, action RowAction) (RowSelectionResult, error) {
	payload := struct {
		Rows      []string     `json:"rows"`
		Selection RowSelection `json:"selection"`
		Action    RowAction    `json:"action"`
	}{nonNil(rows), selection, action}
	var result RowSelectionResult
	if err := c.Execute(ctx, "workspace.rowSelection.reduce", payload, &result); err != nil {
		return RowSelectionResult{}, err
	}
	result.Selection.Marked, result.Targets = nonNil(result.Selection.Marked), nonNil(result.Targets)
	return result, nil
}

// ProjectTreeNode is a project tree node the host loaded: its path, relative to the project
// root with "/" separators and empty for the root, its depth, 0 for the root, and whether it is
// a folder the user opened.
type ProjectTreeNode struct {
	Path  string `json:"path"`
	Depth int    `json:"depth"`
	Open  bool   `json:"open,omitempty"`
}

// ProjectTreeQuery is the shape of the project tree after a change.
type ProjectTreeQuery struct {
	// Nodes are the loaded nodes in preorder; the first is the root.
	Nodes     []ProjectTreeNode
	Selection RowSelection
	// Top is the path of the row at the top of the view before the change, nil for none.
	Top *string
}

// ProjectTreeRows is the outcome of one workspace.projectTree.rows.
type ProjectTreeRows struct {
	// Rows are the positions in the query's Nodes of the rows that show, top to bottom.
	Rows      []int        `json:"rows"`
	Selection RowSelection `json:"selection"`
	// SelectionMoved says the selected row is not the one the query selected, because that node
	// went away or a closed folder hides it.
	SelectionMoved bool `json:"selectionMoved"`
	// TopRow is the row the query's Top is now, nil when it no longer shows.
	TopRow  *int     `json:"topRow"`
	Targets []string `json:"targets"`
}

// ProjectTreeRows has Core say which of the loaded nodes show as rows, keep the selection on a
// row that shows and find the row the top of the view was on (workspace.projectTree.rows).
// Nothing reads the disk; hosts ask once per change of the tree's shape, never per paint.
func (c *Client) ProjectTreeRows(ctx context.Context, query ProjectTreeQuery) (ProjectTreeRows, error) {
	payload := struct {
		Nodes     []ProjectTreeNode `json:"nodes"`
		Selection RowSelection      `json:"selection"`
		Top       *string           `json:"top,omitempty"`
	}{nonNil(query.Nodes), query.Selection, query.Top}
	var result ProjectTreeRows
	if err := c.Execute(ctx, "workspace.projectTree.rows", payload, &result); err != nil {
		return ProjectTreeRows{}, err
	}
	result.Rows, result.Targets = nonNil(result.Rows), nonNil(result.Targets)
	result.Selection.Marked = nonNil(result.Selection.Marked)
	return result, nil
}
