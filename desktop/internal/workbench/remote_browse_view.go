package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the folder browser of remote_browse.go in the Remote Development window.

const (
	// remoteRecentWidth is the width of the connection's recent folders beside the folder list.
	remoteRecentWidth = 260
	// remoteFolderRowHeight is the height of a folder's row.
	remoteFolderRowHeight = 26
)

// remoteBrowserView declares the browser: the connection, the path of the folder shown with the
// button to its parent, the connection's recent folders and the folder's subfolders. A click
// selects a subfolder for Open; a double click or Enter lists it.
func (a *App) remoteBrowserView(c ui.C, b *remoteBrowser) {
	language := a.language()
	k := c.Part("browser")
	ui.Column(k).Fill().Pad(16).Gap(10).Children(func() {
		ui.Row(k.Part("connected")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Icon(k, icons.Server).Size(16, 16).Shrink(0).Color(a.colors.Success)
			ui.Text(k, i18n.SharedFormat(language, "desktop.remote.browse.connected", map[string]string{"name": b.name})).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
			ui.Text(k, remoteAddress(b.connection)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		})
		pathLabel := i18n.Shared(language, "desktop.remote.browse.path")
		ui.Row(k.Part("path")).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			if a.gitIconButton(k.Part("up"), i18n.Shared(language, "desktop.remote.browse.up"), icons.ArrowUp, false, b.opening || b.dir == "/" || b.dir == "") {
				c.After(a.upRemoteFolder)
			}
			if ui.TextField(k.Part("field"), &b.path, pathLabel, i18n.Shared(language, "desktop.remote.browse.pathPlaceholder")).Grow(1).MinWidth(0).Disabled(b.opening).Submitted() {
				c.After(a.goRemoteFolder)
			}
			if a.gitIconButton(k.Part("refresh"), i18n.Shared(language, "desktop.remote.browse.refresh"), icons.RefreshCw, false, b.opening || b.loading || b.dir == "") {
				c.After(func() {
					if b := a.remote.browser; b != nil {
						a.performed("remote.browse.refresh", surfaceButton)
						a.listRemoteFolder(b.dir)
					}
				})
			}
		})
		if b.readErr != "" {
			a.remoteNotice(k.Part("read"), icons.CircleAlert, a.theme.Danger, b.readErr)
		}
		if b.err != "" {
			a.remoteNotice(k.Part("error"), icons.CircleX, a.theme.Danger, b.err)
		}
		ui.Row(k.Part("lists")).FillWidth().Grow(1).Shrink(1).MinHeight(0).Gap(0).
			Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Children(func() {
			if len(b.recent) > 0 {
				a.remoteRecentFolders(k.Part("recent"), b)
				ui.Column(k).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
			}
			a.remoteFolderList(k.Part("folders"), b)
		})
		if text := remoteSkippedText(language, b.skipped); text != "" {
			ui.Paragraph(k.Part("skipped"), text, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
}

// remoteRecentFolders declares the folders opened over the connection before; choosing one lists
// it.
func (a *App) remoteRecentFolders(c ui.C, b *remoteBrowser) {
	title := i18n.Shared(a.language(), "desktop.remote.browse.recent")
	ui.Column(c).Width(remoteRecentWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(c.Part("header")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(10).Children(func() {
			ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Ellipsis()
		})
		b.recentList.Label = func(row int) string {
			if row < 0 || row >= len(b.recent) {
				return ""
			}
			return b.recent[row]
		}
		ui.List(c.Part("rows"), &b.recentList, len(b.recent), func(row ui.ListRow) {
			folder := b.recent[row.Index]
			rc := row.C
			row.Element.Height(remoteFolderRowHeight).PadX(10).Gap(8).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover))
			row.Element.Children(func() {
				ui.Icon(rc, icons.Clock).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
				ui.Text(rc, folder).Ellipsis().Shrink(1).MinWidth(0)
			})
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
		if b.recentList.Changed() {
			if at := b.recentList.Selected(); at >= 0 && at < len(b.recent) && !b.opening {
				folder := b.recent[at]
				c.After(func() {
					if dir, ok := remoteFolderPath(folder, ""); ok {
						a.performed("remote.browse.recent", surfaceButton)
						a.listRemoteFolder(dir)
					}
				})
			}
		}
	})
}

// remoteFolderList declares the subfolders of the folder shown.
func (a *App) remoteFolderList(c ui.C, b *remoteBrowser) {
	language := a.language()
	title := i18n.Shared(language, "desktop.remote.browse.folders")
	ui.Column(c).Grow(1).Shrink(1).MinWidth(0).FillHeight().Children(func() {
		if b.loading || len(b.folders) == 0 {
			text := i18n.Shared(language, "desktop.remote.browse.empty")
			switch {
			case b.loading:
				text = i18n.Shared(language, "native.loading")
			case b.readErr != "":
				text = ""
			}
			ui.Row(c.Part("empty")).FillWidth().Pad(10).Children(func() {
				ui.Paragraph(c, text, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			})
			return
		}
		b.list.Label = func(row int) string {
			if row < 0 || row >= len(b.folders) {
				return ""
			}
			return b.folders[row]
		}
		ui.List(c.Part("rows"), &b.list, len(b.folders), func(row ui.ListRow) {
			name := b.folders[row.Index]
			rc := row.C
			row.Element.Height(remoteFolderRowHeight).PadX(10).Gap(8).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover))
			row.Element.Children(func() {
				ui.Icon(rc, icons.Folder).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
				ui.Text(rc, name).Ellipsis().Shrink(1).MinWidth(0)
			})
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
		if at, ok := b.list.Submitted(); ok && at >= 0 && at < len(b.folders) && !b.opening {
			dir := b.dir + "/" + b.folders[at]
			c.After(func() {
				if dir, ok := remoteFolderPath(dir, ""); ok {
					a.performed("remote.browse.enter", surfaceButton)
					a.listRemoteFolder(dir)
				}
			})
		}
	})
}

// remoteBrowserFooter declares the folder Open opens, Back and Open.
func (a *App) remoteBrowserFooter(c ui.C, b *remoteBrowser) {
	language := a.language()
	if target := b.target(); target != "" {
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.browse.target", map[string]string{"path": target})).Ellipsis().Shrink(1).MinWidth(0).Color(a.colors.Subtle)
	}
	ui.Spacer(c)
	if ui.Button(c.Part("back"), i18n.Shared(language, "desktop.remote.browse.back")).Outline().Disabled(b.opening).Clicked() {
		c.After(a.backFromRemoteBrowser)
	}
	label := i18n.Shared(language, "desktop.remote.browse.open")
	if b.opening {
		label = i18n.Shared(language, "desktop.remote.browse.opening")
	}
	if ui.Button(c.Part("open"), label).Disabled(!b.openable()).Clicked() {
		c.After(a.openRemoteFolder)
	}
}
