package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file declares the Commit tool window's Stash tab: a toolbar, the stash list over the
// files the selected stash saved, and the buttons that apply or pop it, with the dialogs that
// make a stash and confirm dropping one. State and actions are in stash.go.

// stashPageView declares the Stash tab of the open project.
func (a *App) stashPageView(c ui.C, p *project) {
	s := &p.stash
	if s.split.Pos == 0 {
		s.split.Pos = stashListHeight
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.drawStashToolbar(c, p)
		ui.Divider(c)
		if !a.drawCommitStatus(c, p) {
			return
		}
		if !s.loaded && !s.loading {
			a.loadStashes(p)
		}
		for _, problem := range []string{s.err, s.writeErr} {
			if problem != "" {
				ui.Row(c).FillWidth().Shrink(0).PadX(8).PadY(4).Children(func() {
					ui.Paragraph(c, problem, 3).Grow(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				})
			}
		}
		a.drawStashList(c, p).Height(s.split.Pos).Shrink(0)
		ui.Splitter(c, &s.split).Mins(stashListMin, stashFilesMin).Label(a.text.Panel.Resize)
		a.drawStashFiles(c, p).Grow(1)
		ui.Divider(c)
		a.drawStashButtons(c, p)
	})
	if s.pushOpen {
		a.drawStashPushDialog(c, p)
	}
	if s.dropping != nil {
		a.drawStashDropDialog(c, p)
	}
}

// drawStashToolbar declares the buttons over the stash list, as on macOS: read the stashes
// again, show the selected file's diff, stash the local changes, and open or close every
// folder of the files.
func (a *App) drawStashToolbar(c ui.C, p *project) {
	s, lang := &p.stash, a.language()
	repository := p.git.isRepository()
	changes, _ := p.git.changeCount()
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.gitReview.refresh"), icons.RefreshCw, false, !repository || s.loading) {
			c.After(func() { a.loadStashes(p) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.showDiff"), icons.Eye, false, s.tree.file.path == "") {
			file := s.tree.file.path
			c.After(func() { a.openStashFile(p, file) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.gitReview.stashPush"), icons.Archive, false, !repository || s.busy || changes == 0) {
			c.After(func() { a.openStashPush(p) })
		}
		folders := !s.tree.hasFolders()
		if a.gitIconButton(c, i18n.Shared(lang, "outline.expandAll"), icons.ChevronsUpDown, false, folders) {
			c.After(func() { s.tree.openFolders(true) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "files.collapseAll"), icons.ChevronsDownUp, false, folders) {
			c.After(func() { s.tree.openFolders(false) })
		}
	})
}

// drawStashList declares the repository's stashes, newest first: each with its message, its
// name and its date. A click selects one, and its context menu applies, pops or drops it.
func (a *App) drawStashList(c ui.C, p *project) ui.Box {
	s, lang := &p.stash, a.language()
	return ui.Column(c).FillWidth().Clip().Children(func() {
		if len(s.list) == 0 {
			message := i18n.Shared(lang, "native.noSavedChanges")
			if !s.loaded {
				message = a.text.Git.Loading
			}
			a.gitEmpty(c, message)
			return
		}
		selected := slices.IndexFunc(s.list, func(stash core.GitStash) bool { return stash.OID == s.selected })
		if !s.stashes.Changed() && s.stashes.Selected() != selected {
			s.stashes.Select(selected)
		}
		ui.List(c, &s.stashes, len(s.list), func(row ui.ListRow) { a.drawStashRow(p, row, row.Index == selected) }).Grow(1).FillWidth()
		if s.stashes.Changed() {
			if i := s.stashes.Selected(); i >= 0 && i < len(s.list) {
				oid := s.list[i].OID
				c.After(func() { a.selectStash(p, oid) })
			}
		}
	})
}

// drawStashRow declares the row of one stash, with the context menu of its actions.
func (a *App) drawStashRow(p *project, row ui.ListRow, selected bool) {
	s, lang := &p.stash, a.language()
	stash := p.stash.list[row.Index]
	box := row.Element.Height(logItemHeight).Items(ui.Center).Gap(6).PadX(8).Radius(a.theme.Metrics.RadiusItem())
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	ui.ContextMenu(row.C, box, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "git.applyStash")).Disabled(s.busy).Clicked() {
			row.C.After(func() { a.applyStash(p, stash, false) })
		}
		if menu.Item(i18n.Shared(lang, "git.popStash")).Disabled(s.busy).Clicked() {
			row.C.After(func() { a.applyStash(p, stash, true) })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "git.dropStash")).Destructive().Disabled(s.busy).Clicked() {
			row.C.After(func() { s.confirmDropStash(stash) })
		}
	})
	box.Children(func() {
		ui.Icon(row.C, icons.Archive).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(row.C, stash.Message).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(row.C)
		ui.Text(row.C, stash.Reference).Muted().Shrink(0)
		ui.Text(row.C, stashDate(stash)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

// drawStashFiles declares the files the selected stash saved, grouped by folder, or why there
// are none to show.
func (a *App) drawStashFiles(c ui.C, p *project) ui.Box {
	s, lang := &p.stash, a.language()
	return ui.Column(c).FillWidth().Clip().Children(func() {
		switch {
		case s.selected == "":
			a.gitEmpty(c, i18n.Shared(lang, "native.selectSavedChanges"))
		case s.filesLoading:
			a.gitEmpty(c, a.text.Git.LoadingFiles)
		case s.filesErr != "":
			a.panelMessage(c, s.filesErr, a.theme.Danger)
		case len(s.files) == 0:
			a.gitEmpty(c, i18n.Shared(lang, "git.diff.noChangesInStash"))
		default:
			a.drawSavedFileList(c, &s.tree, func(file savedPath) { a.openStashFile(p, file.path) })
		}
	})
}

// drawStashButtons declares the buttons under the files that apply or pop the selected stash.
func (a *App) drawStashButtons(c ui.C, p *project) {
	s, lang := &p.stash, a.language()
	stash, ok := s.selectedStash()
	ui.Row(c).Height(logToolbarHeight + 6).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.git.apply")).Disabled(!ok || s.busy).Clicked() {
			c.After(func() { a.applyStash(p, stash, false) })
		}
		if ui.Button(c, i18n.Shared(lang, "native.pop")).Outline().Disabled(!ok || s.busy).Clicked() {
			c.After(func() { a.applyStash(p, stash, true) })
		}
	})
}

// drawStashPushDialog declares the dialog that stashes the local changes: the stash's message
// and whether the untracked files go into it too.
func (a *App) drawStashPushDialog(c ui.C, p *project) {
	s, lang := &p.stash, a.language()
	title := i18n.Shared(lang, "desktop.gitReview.stashPush")
	open, submitted := true, false
	spec := ui.ModalSpec{Width: 440, Description: i18n.Shared(lang, "native.storeTemporaryChangesInGitSStashList")}
	closed := ui.ModalWith(c, &open, title, spec, func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			label := i18n.Shared(lang, "git.stashMessage")
			submitted = ui.TextField(c, &s.message, label, label).FillWidth().Submitted()
			ui.Checkbox(c, &s.untracked, i18n.Shared(lang, "git.saved.untracked"))
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, title).Disabled(s.busy).Clicked() {
			submitted = true
		}
	})
	switch {
	case submitted && !s.busy:
		c.After(func() { a.pushStash(p) })
	case closed || !open:
		c.After(func() { s.pushOpen = false })
	}
}

// drawStashDropDialog declares the dialog that confirms dropping a stash, which cannot be
// undone.
func (a *App) drawStashDropDialog(c ui.C, p *project) {
	s, lang := &p.stash, a.language()
	stash := *s.dropping
	open, drop := true, false
	spec := ui.ModalSpec{Width: 420, Description: i18n.Shared(lang, "native.thisRemovesTheStashFromGitAndCannotBeUndone")}
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "native.dropStash"), spec, func() {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			ui.Text(c, stash.Message).Color(a.colors.Text).Ellipsis()
			ui.Text(c, stash.Reference).Muted()
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "git.delete")).Destructive().Disabled(s.busy).Clicked() {
			drop = true
		}
	})
	switch {
	case drop && !s.busy:
		c.After(func() { a.dropStash(p) })
	case closed || !open:
		c.After(func() { s.dropping = nil })
	}
}
