package workbench

import (
	"path"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
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
		if a.gitIconButton(c, i18n.Shared(lang, "git.showDiff"), icons.Eye, false, s.file == "") {
			file := s.file
			c.After(func() { a.openStashFile(p, file) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.gitReview.stashPush"), icons.Archive, false, !repository || s.busy || changes == 0) {
			c.After(func() { a.openStashPush(p) })
		}
		folders := len(s.folders) == 0
		if a.gitIconButton(c, i18n.Shared(lang, "outline.expandAll"), icons.ChevronsUpDown, false, folders) {
			c.After(func() { s.openStashFolders(true) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "files.collapseAll"), icons.ChevronsDownUp, false, folders) {
			c.After(func() { s.openStashFolders(false) })
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
			a.drawStashFileList(c, p)
		}
	})
}

// drawStashFileList declares the list of the stash's files. Selecting a file keeps it for the
// Show Diff button; Enter or a double click opens its diff, and on a folder opens or closes it.
func (a *App) drawStashFileList(c ui.C, p *project) {
	s := &p.stash
	s.collectStashFiles()
	if s.fileList.Key == nil {
		s.fileList.Key = func(i int) int { return s.rows[i].key }
	}
	if !s.fileList.Changed() && s.fileList.Selected() != s.fileSelected {
		s.fileList.Select(s.fileSelected)
	}
	ui.List(c, &s.fileList, len(s.rows), func(row ui.ListRow) { a.drawStashFileRow(p, row) }).Grow(1).FillWidth()
	if s.fileList.Changed() {
		if i := s.fileList.Selected(); i >= 0 && i < len(s.rows) {
			if r := s.rows[i]; r.file >= 0 {
				s.file = s.files[r.file].Path
			} else {
				s.file = ""
			}
		}
	}
	if i, ok := s.fileList.Submitted(); ok && i >= 0 && i < len(s.rows) {
		if r := s.rows[i]; r.file < 0 {
			c.After(func() { s.toggleStashFolder(r.folder) })
		} else {
			file := s.files[r.file].Path
			c.After(func() { a.openStashFile(p, file) })
		}
	}
}

// drawStashFileRow declares one row of the stash's files: a folder's arrow, icon and path, or a
// file's change, icon and name in the color of its change.
func (a *App) drawStashFileRow(p *project, row ui.ListRow) {
	s := &p.stash
	r := s.rows[row.Index]
	box := row.Element.Height(treelist.RowHeight).Items(ui.Center).Gap(treelist.Gap).
		PadSides(0, treelist.Gutter+treelist.Trailing, 0, float32(treelist.Gutter+r.depth*treelist.Indent)).
		Radius(a.theme.Metrics.RadiusItem())
	if row.Index == s.fileSelected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	box.Children(func() {
		if r.file < 0 {
			dir := s.folders[r.folder].dir
			a.drawStashFolderArrow(row.C, s, r, dir)
			ui.Icon(row.C, fileicons.ForDirectory(path.Base(dir), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
			ui.Text(row.C, dir).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis()
			return
		}
		file := s.files[r.file]
		color := a.fileStatusColor(file.Status)
		ui.Row(row.C.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
		ui.Text(row.C, statusLetter(file.Status)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(color).Width(logFileStatus).Shrink(0)
		ui.Icon(row.C, fileicons.ForFile(path.Base(file.Path), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		ui.Text(row.C, path.Base(file.Path)).FontSize(treeFontSize).Color(color).Ellipsis()
	})
}

// drawStashFolderArrow declares the arrow that opens or closes a folder of the stash's files.
func (a *App) drawStashFolderArrow(c ui.C, s *stashState, r stashFileRow, dir string) {
	open := !s.closed[dir]
	name, chevron := i18n.Shared(a.language(), "native.collapseDirectory"), icons.ChevronDown
	if !open {
		name, chevron = i18n.Shared(a.language(), "native.expandDirectory"), icons.ChevronRight
	}
	k := c.Part("arrow")
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), name+" "+dir, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(k, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		folder := r.folder
		c.After(func() { s.toggleStashFolder(folder) })
	}
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
