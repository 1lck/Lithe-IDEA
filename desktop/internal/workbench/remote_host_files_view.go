package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// remoteHostFilesRowHeight is the height of a row of the popup's list.
const remoteHostFilesRowHeight = 28

// remoteHostFilesPopup declares Open File on Host (remote_host_files.go) while it is open: it
// hangs from the top of the window as Search Everywhere does, and a press outside closes it.
func (a *App) remoteHostFilesPopup(c ui.C) {
	p := a.project
	if p == nil || p.remote == nil || !p.remote.hostFiles.open {
		return
	}
	f := &p.remote.hostFiles
	a.syncRemoteHostFiles(p)
	if f.focus {
		c.Canvas().RequestFocus(remoteHostFilesQueryID)
		f.focus = false
	}
	language := a.language()
	bounds := c.Bounds()
	width := min(float32(640), max(0, bounds.Width-32))
	height := min(float32(420), max(120, bounds.Height-100)) - 16
	var anchor ui.Box
	ui.Stack(c.Part("remote-host-files-anchor")).Fill().Children(func() {
		anchor = ui.Row(c).Absolute().Left((bounds.Width - width) / 2).Top(84).Width(width).Height(1)
	})
	closed := ui.Popover(c.Part("remote-host-files"), anchor, &f.open, ui.PopoverSpec{
		Width: width, Offset: 1, Align: ui.Start, KeepOpenOnAnchor: true,
	}, func() {
		ui.Column(c).FillWidth().Height(height).Gap(8).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.remote.hostFile.title")).Bold().Shrink(0)
				ui.Text(c, p.remote.remoteLocation()).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			})
			ui.TextField(c, &f.query, i18n.Shared(language, "desktop.remote.hostFile.title"),
				i18n.Shared(language, "desktop.remote.hostFile.placeholder"), ui.WithID(remoteHostFilesQueryID)).Icon(icons.FolderOpen)
			a.remoteHostFilesList(c, p)
			if text := remoteSkippedText(language, f.skipped); text != "" {
				ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
			ui.Paragraph(c, i18n.Shared(language, "desktop.remote.hostFile.readOnlyNote"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	})
	if closed {
		p.closeRemoteHostFiles()
	}
}

// remoteHostFilesList declares the entries shown, or why there are none.
func (a *App) remoteHostFilesList(c ui.C, p *project) {
	f := &p.remote.hostFiles
	language := a.language()
	if f.loading || f.readErr != "" || len(f.rows) == 0 {
		text := i18n.Shared(language, "desktop.remote.hostFile.empty")
		color := a.colors.Subtle
		switch {
		case f.loading:
			text = i18n.Shared(language, "native.loading")
		case f.readErr != "":
			text, color = f.readErr, a.theme.Danger
		}
		ui.Column(c.Part("remote-host-files-empty")).FillWidth().Grow(1).MinHeight(0).Pad(12).Children(func() {
			ui.Paragraph(c, text, 3).FontSize(a.theme.Metrics.FontSizeS).Color(color)
		})
		return
	}
	f.list.Label = func(row int) string {
		if row < 0 || row >= len(f.rows) {
			return ""
		}
		return f.entries[f.rows[row]].name
	}
	// The list learns its row count when it is declared, so a selection made before is applied
	// on the next paint; only a selection that moved scrolls the list.
	if f.selected != f.list.Selected() {
		f.list.Select(f.selected)
	}
	if f.selected != f.scrolledTo {
		f.scrolledTo = f.selected
		f.list.ScrollIntoView(f.selected)
	}
	chosen := -1
	ui.List(c.Part("remote-host-files-rows"), &f.list, len(f.rows), func(row ui.ListRow) {
		rc := row.C
		entry := f.entries[f.rows[row.Index]]
		icon := icons.File
		if entry.folder {
			icon = icons.Folder
		}
		row.Element.FillWidth().Height(remoteHostFilesRowHeight).PadX(10).Gap(8).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Icon(rc, icon).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
			name := entry.name
			if entry.folder {
				name += "/"
			}
			ui.Text(rc, name).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
		})
		if row.Element.Clicked() {
			chosen = row.Index
		}
	}).Scrollbars().Label(i18n.Shared(language, "desktop.remote.hostFile.title")).FillWidth().Grow(1).MinHeight(0)
	if chosen >= 0 {
		f.selected = chosen
		c.After(func() { a.chooseRemoteHostRow(p, chosen, surfaceButton) })
		return
	}
	if f.list.Changed() {
		f.selected = max(f.list.Selected(), 0)
	}
}

// remoteHostFilesKey moves the selection with the arrows, chooses with Enter and completes the
// selected name with Tab while the keyboard is in the popup's field. A plain key typed in a text
// field is the field's, so the popup cannot declare these as shortcuts.
func (a *App) remoteHostFilesKey(p *project, event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Target != remoteHostFilesQueryID || event.Modifiers != 0 {
		return gfx.EventResult{}
	}
	if input := a.root.TextInput(app.TextInputContext{ID: remoteHostFilesQueryID}); input != nil && input.Editor != nil {
		if _, composing := input.Editor.Composition(); composing {
			return gfx.EventResult{}
		}
	}
	f := &p.remote.hostFiles
	switch event.Key {
	case gfx.KeyUp:
		f.selected = max(0, f.selected-1)
	case gfx.KeyDown:
		f.selected = min(max(0, len(f.rows)-1), f.selected+1)
	case gfx.KeyTab:
		p.completeRemoteHostRow(f.selected)
	case gfx.KeyEnter:
		a.submitRemoteHostFiles(p, surfaceShortcut)
	case gfx.KeyEscape:
		p.closeRemoteHostFiles()
	default:
		return gfx.EventResult{}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}
