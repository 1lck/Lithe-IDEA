package workbench

import (
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file is the Git submenu of a file in the project tree (the file half of matrix id
// git-explorer-context-actions, plus the blame, comparison, rollback and history actions the Git
// tool window already runs). Each item applies to the file the menu was opened for; a file the
// repository does not track shows no blame, and a file without a change shows no rollback.

// treeGitMenuBranches bounds the branches the compare submenu lists.
const treeGitMenuBranches = 30

// treeGitMenu declares the Git submenu of the file at n. It is a no-op outside a repository.
func (a *App) treeGitMenu(c ui.C, p *project, n *treeNode, menu *ui.MenuItems) {
	if n.dir || !p.git.isRepository() {
		return
	}
	lang := a.language()
	change, changed := p.git.changeAt(n.path)
	tracked := !changed || (!change.Untracked && change.Status != "??" && !strings.HasPrefix(change.Status, "A"))
	menu.Sub(i18n.Shared(lang, "desktop.files.gitSubmenu"), func(sub *ui.MenuItems) {
		if tracked && sub.Item(i18n.Shared(lang, "git.blame.annotate")).Clicked() {
			c.After(func() { a.openBlame(p, n.path) })
		}
		if sub.Item(i18n.Shared(lang, "desktop.files.showHistory")).Clicked() {
			c.After(func() { a.showFileHistory(p, n.path) })
		}
		a.treeCompareMenu(c, p, sub, n)
		if changed {
			sub.Separator()
			if sub.Item(i18n.Shared(lang, "git.rollback")).Destructive().Clicked() {
				c.After(func() { a.openRollback(p, []core.GitChange{change}) })
			}
		}
	})
}

// treeCompareMenu declares the compare submenu: each local branch, and the working tree's
// differences with it for the file.
func (a *App) treeCompareMenu(c ui.C, p *project, sub *ui.MenuItems, n *treeNode) {
	lang := a.language()
	var branches []core.GitReference
	for _, r := range p.log.refs.References {
		if r.Kind == "local" && len(branches) < treeGitMenuBranches {
			branches = append(branches, r)
		}
	}
	if len(branches) == 0 {
		return
	}
	sub.Sub(i18n.Shared(lang, "desktop.files.compareBranch"), func(branchMenu *ui.MenuItems) {
		for _, r := range branches {
			ref := r
			if branchMenu.Item(ref.ShortName).Clicked() {
				c.After(func() { a.compareReferences(p, ref, nil) })
			}
		}
	})
}

// showFileHistory shows the Git tool window's Log tab narrowed to the commits that changed the file
// at rel, which is project-relative.
func (a *App) showFileHistory(p *project, rel string) {
	a.performed("git.showFileHistory", surfaceMenu)
	a.layout.gitTab = gitTabLog
	if !a.chrome.isOpen(catalogIndex[itemGit]) {
		a.reduceChrome(core.SetChromeOpen(itemGit, true))
	}
	a.showLogFileHistory(p, filepath.ToSlash(rel))
}
