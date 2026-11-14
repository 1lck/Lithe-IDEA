package workbench

import (
	"context"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the multi-selection of the Commit window's change rows (matrix id
// git-local-changelists): a Cmd or Ctrl click adds or removes a row, a Shift click selects the rows
// between the anchor and the clicked row, and a plain click clears the selection. The selection
// moves the changes it holds to a change list together; it is dropped when the active list changes
// and when the changes move, so a result read for another list is never applied to these rows.

// selectedChanges are the changes of the project's status whose paths the selection holds, in the
// order the status lists them.
func (p *project) selectedChanges() []core.GitChange {
	var out []core.GitChange
	for _, change := range p.git.status.Changes {
		if p.lists.selected[change.Path] {
			out = append(out, change)
		}
	}
	return out
}

// clickChangeRow applies a click on the row of change with the modifiers it came with, as Core
// says (workspace.rowSelection.reduce over the changes in the order they show). A plain click
// drops the marks; the row a click opens is the review's business, not the selection's.
func (a *App) clickChangeRow(p *project, change core.GitChange, mods gfx.Modifiers) {
	l := &p.lists
	action := core.ClearRows()
	switch {
	case mods&ui.Primary != 0:
		action = core.ToggleRow(change.Path)
	case mods&gfx.ModifierShift != 0:
		action = core.ExtendRow(change.Path)
	}
	rows := make([]string, len(p.git.status.Changes))
	for i, c := range p.git.status.Changes {
		rows[i] = c.Path
	}
	selection := core.RowSelection{Anchor: l.anchor}
	for at := range l.selected {
		selection.Marked = append(selection.Marked, at)
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ReduceRowSelection(ctx, rows, selection, action)
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		return
	}
	if result.Rejection != "" {
		return
	}
	l.selected = nil
	if len(result.Selection.Marked) > 0 {
		l.selected = make(map[string]bool, len(result.Selection.Marked))
		for _, at := range result.Selection.Marked {
			l.selected[at] = true
		}
	}
	l.anchor = result.Selection.Anchor
}

// changeListBatchMenu declares the batch items of a selected change's menu: how many changes the
// move takes, then the lists to move them to.
func (a *App) changeListBatchMenu(c ui.C, p *project, changes []core.GitChange, menu *ui.MenuItems) {
	lang := a.language()
	menu.Sub(i18n.SharedFormat(lang, "desktop.changelists.moveSelected", map[string]string{"count": strconv.Itoa(len(changes))}), func(sub *ui.MenuItems) {
		for _, list := range p.lists.state.Lists {
			id := list.ID
			if sub.Item(a.changeListName(list)).Clicked() {
				c.After(func() { a.moveToChangeList(p, changes, id) })
			}
		}
	})
}

// discardListResults drops what was read for the active list: the selection, the running message
// generation, a generated message waiting for the user's word, and a diff still being read. A
// diff tab that was loading reads again, so its answer comes from the state the new list shows
// and the answer for the old one is never applied (loadDiff drops it by its generation).
func (a *App) discardListResults(p *project) {
	p.lists.selected, p.lists.anchor = nil, ""
	a.cancelCommitGeneration(p)
	p.commit.ai.pending, p.commit.ai.hasPending = "", false
	for _, t := range p.diffs.list {
		if t.loading {
			a.loadDiff(p, t)
		}
	}
}
