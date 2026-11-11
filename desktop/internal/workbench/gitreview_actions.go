package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// openChange opens what a double click on a change of the Commit window shows: the Diff of a
// file, or the listing of a summarized untracked directory.
func (a *App) openChange(p *project, change core.GitChange) {
	if strings.HasSuffix(change.Path, "/") {
		a.openUntracked(p, change.Path)
		return
	}
	a.openDiff(p, change)
}

// changeMenuItems are the Git actions of one change of the Commit window. They apply to the
// change the menu was opened for, never to a row index, which moves when the status reloads.
func (a *App) changeMenuItems(c ui.C, p *project, change core.GitChange) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		menu.WidthRange(220, 320)
		if sel := p.selectedChanges(); len(sel) > 1 && p.lists.selected[change.Path] && !p.lists.hidden {
			a.changeListBatchMenu(c, p, sel, menu)
			return
		}
		if _, ok := a.reviewKernel(); !ok {
			a.changeListMenuItems(c, p, change, menu)
			return
		}
		folder := strings.HasSuffix(change.Path, "/")
		if folder {
			if menu.Item(i18n.Shared(a.language(), "desktop.gitReview.untrackedMenu")).Clicked() {
				c.After(func() { a.openUntracked(p, change.Path) })
			}
		} else if menu.Item(i18n.Shared(a.language(), "git.showDiff")).Clicked() {
			c.After(func() { a.openDiff(p, change) })
		}
		tracked := !change.Untracked && change.Status != "??" && !strings.HasSuffix(change.Status, "A") && !strings.HasPrefix(change.Status, "A")
		if !folder && tracked && menu.Item(i18n.Shared(a.language(), "git.blame.annotate")).Clicked() {
			c.After(func() { a.openBlame(p, change.Path) })
		}
		if change.Untracked || change.Status == "??" {
			if menu.Item(i18n.Shared(a.language(), "desktop.git.excludeLocally")).Clicked() {
				c.After(func() { a.excludeLocally(p, change) })
			}
		}
		a.changeListMenuItems(c, p, change, menu)
		menu.Separator()
		if menu.Item(i18n.Shared(a.language(), "git.rollback")).Destructive().Clicked() {
			c.After(func() { a.openRollback(p, []core.GitChange{change}) })
		}
	}
}
