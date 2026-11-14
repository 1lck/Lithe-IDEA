package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The rows of the project tree and its selection follow Core's rules (matrix id
// workspace-tree-batch-files): which loaded nodes show, where a selection goes when its node
// goes away or a closed folder hides it, and what a click with or without Cmd, Ctrl or Shift
// does to the selected row, the marked rows and the anchor. The tree keeps the nodes it listed,
// which folders are open, focus, scrolling and painting, and asks Core once per change of the
// tree's shape, never per paint.

// refreshTreeRows has Core lay out the rows of the tree after its shape changed, keep the
// selection on a row that shows, and scroll the row named by top, the path of the row at the
// top of the view before the change, back to the top; nil leaves the scroll as it is. It
// reports whether the selection moved. When Core cannot say, the banner says why and the rows
// stay as they were.
func (a *App) refreshTreeRows(p *project, top *string) bool {
	t := &p.tree
	if t.root == nil {
		return false
	}
	t.rowsDirty = false
	var order []*treeNode
	var nodes []core.ProjectTreeNode
	var walk func(*treeNode)
	walk = func(n *treeNode) {
		order = append(order, n)
		nodes = append(nodes, core.ProjectTreeNode{Path: n.path, Depth: n.depth, Open: n.dir && n.expanded})
		for _, child := range n.children {
			walk(child)
		}
	}
	walk(t.root)
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ProjectTreeRows(ctx, core.ProjectTreeQuery{Nodes: nodes, Selection: t.selection(), Top: top})
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		return false
	}
	t.rows = t.rows[:0]
	for _, i := range result.Rows {
		t.rows = append(t.rows, order[i])
	}
	t.adopt(result.Selection, result.Targets)
	if result.TopRow != nil {
		t.view.ScrollTo(*result.TopRow, ui.ListStart)
	}
	t.measureDirty = true
	return result.SelectionMoved
}

// treeTopPath is the path of the row at the top of the view, and nil while the view is
// scrolled to its top, where the first row stays in view whatever comes above the others.
func treeTopPath(t *fileTree) *string {
	first, last := t.view.Visible()
	if first <= 0 || first > last || first+treeOverscan >= len(t.rows) {
		return nil
	}
	return new(t.rows[first+treeOverscan].path)
}

// reduceTreeSelection applies a click on a row, or the end of a batch, to the tree's selection
// as Core says. It reports whether the selection changed: a click on a row that went away
// changes nothing, and when Core cannot say the banner says why.
func (a *App) reduceTreeSelection(p *project, action core.RowAction) bool {
	t := &p.tree
	if t.rowsDirty {
		a.refreshTreeRows(p, nil)
	}
	rows := make([]string, len(t.rows))
	for i, n := range t.rows {
		rows[i] = n.path
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ReduceRowSelection(ctx, rows, t.selection(), action)
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		return false
	}
	if result.Rejection != "" {
		return false
	}
	t.adopt(result.Selection, result.Targets)
	return true
}

// selection is the tree's selection as Core takes it.
func (t *fileTree) selection() core.RowSelection {
	s := core.RowSelection{Anchor: t.anchor}
	if t.selected != nil {
		s.Selected = new(t.selected.path)
	}
	for at := range t.marked {
		s.Marked = append(s.Marked, at)
	}
	return s
}

// adopt takes the selection and the batch targets Core answered.
func (t *fileTree) adopt(selection core.RowSelection, targets []string) {
	t.selected = nil
	if selection.Selected != nil {
		t.selected = t.find(*selection.Selected)
	}
	t.marked = nil
	if len(selection.Marked) > 0 {
		t.marked = make(map[string]bool, len(selection.Marked))
		for _, at := range selection.Marked {
			t.marked[at] = true
		}
	}
	t.anchor, t.targets = selection.Anchor, targets
}
