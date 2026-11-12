package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// This file holds the Git actions of the project tree's context menu (matrix id
// git-explorer-context-actions): staging a changed file and opening the Commit tool window
// in the same step, and opening the Commit tool window from a folder, which shows the
// repository the project's tree belongs to. The menu itself is declared in filetree_menu.go.

// stageChangeAndShowCommit stages or unstages change as stageChange does, then opens the
// Commit tool window that lists it. Nothing happens while a commit step or another staging
// change is running, which stageChange would refuse anyway.
func (a *App) stageChangeAndShowCommit(p *project, change core.GitChange) {
	if p.commit.busy || !change.CanToggleStaging {
		return
	}
	a.stageChange(p, change)
	a.showChanges()
}
