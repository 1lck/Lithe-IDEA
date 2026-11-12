package workbench

import (
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

// clickChangeRow applies a click on the row of change with the modifiers it came with.
func (a *App) clickChangeRow(p *project, change core.GitChange, mods gfx.Modifiers) {
	l := &p.lists
	switch {
	case mods&ui.Primary != 0:
		if l.selected == nil {
			l.selected = map[string]bool{}
		}
		if l.selected[change.Path] {
			delete(l.selected, change.Path)
		} else {
			l.selected[change.Path] = true
		}
		l.anchor = change.Path
	case mods&gfx.ModifierShift != 0:
		if l.selected == nil {
			l.selected = map[string]bool{}
		}
		from := l.anchor
		if from == "" {
			from = change.Path
		}
		lo, hi := changeRowIndex(p.git.status.Changes, from), changeRowIndex(p.git.status.Changes, change.Path)
		if lo > hi {
			lo, hi = hi, lo
		}
		for i := max(lo, 0); i <= hi && i < len(p.git.status.Changes); i++ {
			l.selected[p.git.status.Changes[i].Path] = true
		}
	default:
		l.selected, l.anchor = nil, ""
	}
}

// changeRowIndex is the index of the change at path in changes, -1 when there is none.
func changeRowIndex(changes []core.GitChange, path string) int {
	for i, change := range changes {
		if change.Path == path {
			return i
		}
	}
	return -1
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
