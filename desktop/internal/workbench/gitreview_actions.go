package workbench

import (
	"path/filepath"
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
		lang := a.language()
		folder := strings.HasSuffix(change.Path, "/")
		full := filepath.Join(p.git.repositoryRoot(p.root), filepath.FromSlash(strings.TrimSuffix(change.Path, "/")))
		deleted := strings.ContainsRune(change.Status, 'D')
		if !folder && !deleted && menu.Item(i18n.Shared(lang, "desktop.files.open")).Clicked() {
			c.After(func() {
				a.performed("git.change.open", surfaceMenu)
				a.openFile(p, full)
			})
		}
		if folder {
			if menu.Item(i18n.Shared(lang, "desktop.gitReview.untrackedMenu")).Clicked() {
				c.After(func() { a.openUntracked(p, change.Path) })
			}
		} else if menu.Item(i18n.Shared(lang, "git.showDiff")).Clicked() {
			c.After(func() { a.openDiff(p, change) })
		}
		tracked := !change.Untracked && change.Status != "??" && !strings.HasSuffix(change.Status, "A") && !strings.HasPrefix(change.Status, "A")
		if !folder && tracked && menu.Item(i18n.Shared(lang, "git.blame.annotate")).Clicked() {
			c.After(func() { a.openBlame(p, change.Path) })
		}
		menu.Separator()
		untracked := change.Untracked || change.Status == "??"
		stage := stagesChange(change)
		label := i18n.Shared(lang, "desktop.files.unstage")
		switch {
		case untracked:
			label = i18n.Shared(lang, "vcs.commitFiles.addToVcs")
		case stage:
			label = i18n.Shared(lang, "desktop.files.stage")
		}
		if menu.Item(label).Disabled(p.commit.busy || !change.CanToggleStaging).Clicked() {
			c.After(func() { a.stageChange(p, change) })
		}
		if untracked {
			if menu.Item(i18n.Shared(lang, "desktop.git.excludeLocally")).Clicked() {
				c.After(func() { a.excludeLocally(p, change) })
			}
		}
		a.changeListMenuItems(c, p, change, menu)
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "git.rollback")).Destructive().Clicked() {
			c.After(func() { a.openRollback(p, []core.GitChange{change}) })
		}
		rel, inside := projectRelative(p.root, full)
		if !deleted && inside && rel != "" && menu.Item(i18n.Shared(lang, "desktop.files.delete")).Clicked() {
			c.After(func() { a.openTreeRemoval(p, []string{rel}) })
		}
		menu.Separator()
		if !deleted && menu.Item(revealLabel(lang)).Clicked() {
			c.After(func() {
				a.performed("git.change.reveal", surfaceMenu)
				a.revealPath(full)
			})
		}
		a.copyPathMenu(c, menu, full, true, "git.change")
	}
}
