package workbench

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file declares the Commit tool window's Shelf tab: a toolbar, the shelf list over the
// files the selected shelf saved, grouped under the staged changes and the working tree's, and
// the button that restores it, with the dialogs that shelve the local changes and confirm
// dropping a shelf. State and actions are in shelf.go.

// shelfPageView declares the Shelf tab of the open project.
func (a *App) shelfPageView(c ui.C, p *project) {
	s := &p.shelf
	if s.split.Pos == 0 {
		s.split.Pos = stashListHeight
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.drawShelfToolbar(c, p)
		ui.Divider(c)
		if !a.drawCommitStatus(c, p) {
			return
		}
		if !s.loaded && !s.loading {
			a.loadShelves(p)
		}
		for _, problem := range []string{s.err, s.writeErr} {
			if problem != "" {
				ui.Row(c).FillWidth().Shrink(0).PadX(8).PadY(4).Children(func() {
					ui.Paragraph(c, problem, 3).Grow(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				})
			}
		}
		a.drawShelfList(c, p).Height(s.split.Pos).Shrink(0)
		ui.Splitter(c, &s.split).Mins(stashListMin, stashFilesMin).Label(a.text.Panel.Resize)
		a.drawShelfFiles(c, p).Grow(1)
		ui.Divider(c)
		a.drawShelfButtons(c, p)
	})
	if s.shelveOpen {
		a.drawShelveDialog(c, p)
	}
	if s.dropping != nil {
		a.drawShelfDropDialog(c, p)
	}
}

// drawShelfToolbar declares the buttons over the shelf list: read the shelves again, show the
// selected file's diff, shelve the local changes, and open or close every folder of the files.
func (a *App) drawShelfToolbar(c ui.C, p *project) {
	s, lang := &p.shelf, a.language()
	repository := p.git.isRepository()
	changes, _ := p.git.changeCount()
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.gitReview.refresh"), icons.RefreshCw, false, !repository || s.loading) {
			c.After(func() { a.loadShelves(p) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.showDiff"), icons.Eye, false, s.tree.file.path == "") {
			file := s.tree.file
			c.After(func() { a.openShelfFile(p, file) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "native.shelveChanges"), icons.Archive, false, !repository || s.busy || changes == 0) {
			c.After(func() { a.openShelve(p) })
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

// drawShelfList declares the repository's shelves, newest first: each with its name, the
// number of files it touches and its date. A click selects one, and its context menu restores
// or drops it.
func (a *App) drawShelfList(c ui.C, p *project) ui.Box {
	s, lang := &p.shelf, a.language()
	return ui.Column(c).FillWidth().Clip().Children(func() {
		if len(s.list) == 0 {
			message := i18n.Shared(lang, "native.noShelves")
			if !s.loaded {
				message = a.text.Git.Loading
			}
			a.gitEmpty(c, message)
			return
		}
		selected := slices.IndexFunc(s.list, func(shelf shelfRecord) bool { return shelf.ID == s.selected })
		if !s.shelves.Changed() && s.shelves.Selected() != selected {
			s.shelves.Select(selected)
		}
		ui.List(c, &s.shelves, len(s.list), func(row ui.ListRow) { a.drawShelfRow(p, row, row.Index == selected) }).Grow(1).FillWidth()
		if s.shelves.Changed() {
			if i := s.shelves.Selected(); i >= 0 && i < len(s.list) {
				id := s.list[i].ID
				c.After(func() { a.selectShelf(p, id) })
			}
		}
	})
}

// drawShelfRow declares the row of one shelf, with the context menu of its actions.
func (a *App) drawShelfRow(p *project, row ui.ListRow, selected bool) {
	s, lang := &p.shelf, a.language()
	shelf := s.list[row.Index]
	box := row.Element.Height(logItemHeight).Items(ui.Center).Gap(6).PadX(8).Radius(a.theme.Metrics.RadiusItem())
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	ui.ContextMenu(row.C, box, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "git.saved.restore")).Disabled(s.busy).Clicked() {
			row.C.After(func() { a.restoreShelf(p, shelf) })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "git.delete")).Destructive().Disabled(s.busy).Clicked() {
			row.C.After(func() { s.confirmDropShelf(shelf) })
		}
	})
	box.Children(func() {
		ui.Icon(row.C, icons.Archive).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(row.C, shelf.Message).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(row.C)
		ui.Text(row.C, a.shelfSummary(shelf)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

// shelfSummary is the number of files a shelf touches and the local date it was made.
func (a *App) shelfSummary(shelf shelfRecord) string {
	return i18n.SharedFormat(a.language(), "native.lldFileS", map[string]string{
		"arg1": strconv.Itoa(shelfFileCount(shelf)),
		"arg2": shelf.CreatedAt.Local().Format(logDateFormat),
	})
}

// drawShelfFiles declares the files the selected shelf saved, under the layer each was saved
// from and grouped by folder, or why there are none to show.
func (a *App) drawShelfFiles(c ui.C, p *project) ui.Box {
	s, lang := &p.shelf, a.language()
	return ui.Column(c).FillWidth().Clip().Children(func() {
		switch {
		case s.selected == "":
			a.gitEmpty(c, i18n.Shared(lang, "native.selectSavedChanges"))
		case s.filesLoading:
			a.gitEmpty(c, a.text.Git.LoadingFiles)
		case s.filesErr != "":
			a.panelMessage(c, s.filesErr, a.theme.Danger)
		case s.tree.empty():
			a.gitEmpty(c, i18n.Shared(lang, "native.noSavedChanges"))
		default:
			a.drawSavedFileList(c, &s.tree, func(file savedPath) { a.openShelfFile(p, file) })
		}
	})
}

// drawShelfButtons declares the button under the files that restores the selected shelf.
func (a *App) drawShelfButtons(c ui.C, p *project) {
	s, lang := &p.shelf, a.language()
	shelf, ok := s.selectedShelf()
	ui.Row(c).Height(logToolbarHeight + 6).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		if ui.Button(c, i18n.Shared(lang, "git.saved.restore")).Disabled(!ok || s.busy).Clicked() {
			c.After(func() { a.restoreShelf(p, shelf) })
		}
	})
}

// drawShelveDialog declares the dialog that shelves the local changes under a name.
func (a *App) drawShelveDialog(c ui.C, p *project) {
	s, lang := &p.shelf, a.language()
	title := i18n.Shared(lang, "native.shelveChanges")
	open, submitted := true, false
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 440}, func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			label := i18n.Shared(lang, "native.name")
			submitted = ui.TextField(c, &s.message, label, label).FillWidth().Submitted()
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, title).Disabled(s.busy || strings.TrimSpace(s.message.Text()) == "").Clicked() {
			submitted = true
		}
	})
	switch {
	case submitted && !s.busy:
		c.After(func() { a.shelveChanges(p) })
	case closed || !open:
		c.After(func() { s.shelveOpen = false })
	}
}

// drawShelfDropDialog declares the dialog that confirms dropping a shelf, which cannot be
// undone.
func (a *App) drawShelfDropDialog(c ui.C, p *project) {
	s, lang := &p.shelf, a.language()
	shelf := *s.dropping
	open, drop := true, false
	spec := ui.ModalSpec{Width: 420, Description: i18n.Shared(lang, "native.thisRemovesTheSavedPatchFromLitheAndCannotBeUndone")}
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "git.saved.drop"), spec, func() {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			ui.Text(c, shelf.Message).Color(a.colors.Text).Ellipsis()
			ui.Text(c, a.shelfSummary(shelf)).Muted()
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
		c.After(func() { a.dropShelf(p) })
	case closed || !open:
		c.After(func() { s.dropping = nil })
	}
}
