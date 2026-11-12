package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares what the Commit tool window shows of the local ChangeLists, as the
// macOS one does: the bar over the change list that picks the active list and creates,
// renames or deletes one, the sections the changes are grouped in, the "Move to ChangeList"
// submenu of a change, and the dialogs. The state and the actions are in changelists.go.

// changeListPickerWidth is the width of the list picker of the bar.
const changeListPickerWidth = 220

// changeListName is how a list is shown: the default one by its translated name.
func (a *App) changeListName(list core.ChangeList) string {
	if list.ID == changeListDefaultID || list.Name == "" {
		return a.text.Commit.ChangeList
	}
	return list.Name
}

// changeListNameByID is how the list id is shown.
func (a *App) changeListNameByID(p *project, id string) string {
	list, ok := p.lists.list(id)
	if !ok {
		list = core.ChangeList{ID: id}
	}
	return a.changeListName(list)
}

// drawChangeListBar declares the bar over the change list: the active list, the buttons that
// create, rename and delete one, and why the lists cannot be used when they cannot. Whether a
// commit updates the parent repositories' references is a commit option (drawCommitOptions),
// so the bar fits a narrow tool window.
func (a *App) drawChangeListBar(c ui.C, p *project) {
	if _, ok := a.kernel.(changeListKernel); !ok || p.lists.hidden {
		return
	}
	l, lang, busy := &p.lists, a.language(), p.commit.busy
	active := l.activeID()
	ids := make([]string, 0, len(l.state.Lists))
	for _, list := range l.state.Lists {
		ids = append(ids, list.ID)
	}
	if len(ids) == 0 {
		ids = []string{changeListDefaultID}
	}
	if l.pick == "" {
		l.pick = active
	}
	unusable := !l.read || l.failed != nil
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		help := i18n.Shared(lang, "native.stageAllAndCommitUseTheCurrentChangeList")
		ui.Select(c, &l.pick, ids, func(id string) string { return a.changeListNameByID(p, id) }).
			Label(help).Width(changeListPickerWidth).Disabled(busy || unusable)
		if picked := l.pick; picked != active {
			l.pick = active // shown again once Core activated the list picked
			c.After(func() { a.activateChangeList(p, picked) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "native.newChangeList"), icons.Plus, false, unusable) {
			c.After(func() { a.openChangeListDialog(p, changeListCreate, nil) })
		}
		fixed := unusable || active == changeListDefaultID
		if a.gitIconButton(c, i18n.Shared(lang, "native.renameChangeList"), icons.Pencil, false, fixed) {
			c.After(func() { a.openChangeListDialog(p, changeListRename, nil) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "native.deleteChangeList"), icons.Trash2, false, fixed) {
			c.After(func() { a.openChangeListDialog(p, changeListDelete, nil) })
		}
	})
	if l.failed != nil {
		ui.Paragraph(c, i18n.Shared(lang, "git.changelists.unavailable"), 3).
			FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).PadX(8)
	}
}

// drawChangeListSections declares the changes grouped by list, every list in order with its
// own checkbox that stages or unstages its changes, the active one marked.
func (a *App) drawChangeListSections(c ui.C, p *project) {
	l, t := &p.lists, a.text.Commit
	suffix := i18n.Shared(a.language(), "git.changelists.activeSuffix")
	busy := p.commit.busy || !p.listsReady()
	ui.Scroll(c).Grow(1).FillWidth().PadY(4).Children(func() {
		for _, list := range l.state.Lists {
			changes := p.listChanges(list.ID)
			title := a.changeListName(list)
			if list.ID == l.activeID() {
				title += suffix
			}
			sc := c.Key("changelist/" + list.ID)
			ui.Row(sc).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
				all := allStaged(changes)
				if ui.Checkbox(sc, &all, "").Label(title).Disabled(busy || !hasToggleable(changes)).Clicked() {
					sc.After(func() { a.stageChanges(p, changes, surfaceButton) })
				}
				ui.Text(sc, title).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
				ui.Text(sc, t.Files(fileCount(changes))).Muted().Shrink(0)
			})
			for _, change := range changes {
				a.drawCommitChange(c, p, change)
			}
		}
	})
}

// changeListMenuItems adds the "Move to ChangeList" submenu of change to menu: every other
// list, then a new list that takes it.
func (a *App) changeListMenuItems(c ui.C, p *project, change core.GitChange, menu *ui.MenuItems) {
	l, lang := &p.lists, a.language()
	if _, ok := a.kernel.(changeListKernel); !ok || !l.read || l.failed != nil || l.hidden {
		return
	}
	current := p.changeListOf(change)
	menu.Sub(i18n.Shared(lang, "native.moveToChangeList"), func(sub *ui.MenuItems) {
		others := 0
		for _, list := range l.state.Lists {
			if list.ID == current {
				continue
			}
			others++
			id := list.ID
			if sub.Item(a.changeListName(list)).Clicked() {
				c.After(func() { a.moveToChangeList(p, []core.GitChange{change}, id) })
			}
		}
		if others > 0 {
			sub.Separator()
		}
		if sub.Item(i18n.Shared(lang, "native.newChangeList")).Clicked() {
			c.After(func() { a.openChangeListDialog(p, changeListCreate, []core.GitChange{change}) })
		}
	})
}

// drawChangeListDialog declares the dialog of the lists that is open: the name of a list
// being created or renamed, or the confirmation that deletes one.
func (a *App) drawChangeListDialog(c ui.C, p *project) {
	l, lang := &p.lists, a.language()
	cancel := i18n.Shared(lang, "desktop.git.cancel")
	switch l.dialog {
	case changeListCreate, changeListRename:
		title := i18n.Shared(lang, "native.newChangeList")
		if l.dialog == changeListRename {
			title = i18n.Shared(lang, "native.renameChangeList")
		}
		label := i18n.Shared(lang, "native.name")
		ready := !l.running && l.name.Text() != ""
		open, submitted := true, false
		closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 380}, func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				submitted = ui.TextField(c, &l.name, label, label).FillWidth().AutoFocus().Submitted()
				if l.nameError != "" {
					ui.Paragraph(c, l.nameError, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			})
		}, func() {
			if ui.Button(c, cancel).Outline().Clicked() {
				c.After(func() { a.closeChangeListDialog(p) })
			}
			if ui.Button(c, i18n.Shared(lang, "ui.save")).Disabled(!ready).Clicked() {
				c.After(func() { a.submitChangeListName(p) })
			}
		})
		if submitted && ready {
			c.After(func() { a.submitChangeListName(p) })
		}
		if closed {
			c.After(func() { a.closeChangeListDialog(p) })
		}
	case changeListDelete:
		open := true
		spec := ui.ModalSpec{
			Description: i18n.Shared(lang, "native.filesReturnToTheDefaultChangeListAndMayBeIncludedByStageAllTheirGitStagingStateIsUnchanged"),
			Width:       420,
		}
		closed := ui.ModalWith(c, &open, i18n.Shared(lang, "native.deleteChangeList.variant2"), spec, func() {
			ui.Text(c, a.changeListNameByID(p, l.target)).Weight(gfx.WeightMedium)
		}, func() {
			if ui.Button(c, cancel).Outline().Clicked() {
				c.After(func() { a.closeChangeListDialog(p) })
			}
			if ui.Button(c, i18n.Shared(lang, "git.delete")).Destructive().Disabled(l.running).Clicked() {
				c.After(func() { a.removeChangeList(p) })
			}
		})
		if closed {
			c.After(func() { a.closeChangeListDialog(p) })
		}
	}
}
