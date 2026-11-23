package workbench

import (
	"path"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the folder browser of remote_browse.go in the Remote Development window's page.

// remoteFolderRowHeight is the height of a row of the folder list.
const remoteFolderRowHeight = 34

// remoteBrowserView declares the browser: the connected host, the path field, the folders used
// often, the path of the folder shown and its entries. A click selects a subfolder for Open; a
// double click or Enter lists it. Files show greyed, as what the folder holds. While the host's
// containers are listed, they show in place of all but the head.
func (a *App) remoteBrowserView(c ui.C, b *remoteBrowser) {
	language := a.language()
	k := c.Part("browser")
	ui.Column(k).Fill().Gap(12).PadSides(20, 24, 16, 24).Children(func() {
		a.remoteBrowserHead(k.Part("head"), language, b)
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		if b.containers != nil {
			a.remoteHostContainersView(k.Part("containers"), language, b.containers)
			return
		}
		ui.Row(k.Part("path")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if ui.TextField(k.Part("field"), &b.path, i18n.Shared(language, "desktop.remote.browse.path"), i18n.Shared(language, "desktop.remote.browse.pathPlaceholder")).
				Grow(1).MinWidth(0).Disabled(b.opening).Submitted() {
				c.After(a.goRemoteFolder)
			}
			if ui.Button(k.Part("go"), i18n.Shared(language, "desktop.remote.browse.go")).Outline().Shrink(0).Disabled(b.opening).Clicked() {
				c.After(a.goRemoteFolder)
			}
		})
		a.remoteFolderShortcuts(k, language, b)
		a.remoteFolderCrumbs(k, b)
		if b.readErr != "" {
			a.remoteNotice(k.Part("read"), icons.CircleAlert, a.theme.Danger, b.readErr)
		}
		if b.err != "" {
			a.remoteNotice(k.Part("error"), icons.CircleX, a.theme.Danger, b.err)
		}
		ui.Column(k.Part("entries")).FillWidth().Grow(1).Shrink(1).MinHeight(0).
			Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Clip().Children(func() {
			if b.dir != "" && b.dir != "/" {
				a.remoteFolderUp(k.Part("up"), language, b)
				ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			}
			a.remoteFolderList(k.Part("folders"), b)
		})
		if text := remoteSkippedText(language, b.skipped); text != "" {
			ui.Paragraph(c, text, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
}

// remoteBrowserHead declares the page's head: the host's mark, which host the folder is chosen
// on, that it is connected, its address and system, the host's containers for a host that can
// run them, and Disconnect.
func (a *App) remoteBrowserHead(c ui.C, language i18n.Language, b *remoteBrowser) {
	r := &a.remote
	mark, system := "", ""
	var color core.RemoteConnectionColor
	if entry := r.entry(b.entryID); entry != nil {
		outcome := r.probedOutcome(entry.Connection)
		mark, color = remoteSystemMark(outcome), entry.Color
		system = remoteSystemLine(outcome)
	}
	ui.Row(c).FillWidth().Items(ui.Center).Gap(14).Children(func() {
		a.remoteTile(c.Part("tile"), mark, b.name, color, remoteHeroTile, 15)
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
			title := i18n.SharedFormat(language, "desktop.remote.browse.title", map[string]string{"name": b.name})
			if b.containers != nil {
				title = i18n.SharedFormat(language, "desktop.remote.hostContainers.title", map[string]string{"name": b.name})
			}
			ui.Text(c, title).
				FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
			ui.Row(c.Part("state")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				a.remoteStatusPill(c.Part("live"), i18n.Shared(language, "desktop.remote.browse.connected"), a.colors.Success)
				ui.Text(c, b.host.address()).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				if system != "" {
					ui.Text(c, system).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				}
			})
		})
		if b.hostsContainers() && b.containers == nil &&
			ui.Button(c.Part("containers"), i18n.Shared(language, "desktop.remote.hostContainers.show")).Icon(icons.Server).Outline().Shrink(0).Disabled(b.opening).Clicked() {
			c.After(a.showRemoteHostContainers)
		}
		if ui.Button(c.Part("disconnect"), i18n.Shared(language, "desktop.remote.browse.disconnect")).Outline().Shrink(0).Disabled(b.opening).Clicked() {
			c.After(a.backFromRemoteBrowser)
		}
	})
}

// remoteSystemLine is the tested host's system and processor, such as "Ubuntu 24.04 LTS x86_64",
// or "" for a host never tested.
func remoteSystemLine(outcome *remoteProbeOutcome) string {
	if outcome == nil || outcome.err != nil || outcome.result.Host == nil {
		return ""
	}
	host := outcome.result.Host
	system := strings.TrimSpace(host.Details.OperatingSystem)
	if system == "" {
		system = strings.TrimSpace(host.System)
	}
	return strings.TrimSpace(system + " " + strings.TrimSpace(host.Machine))
}

// remoteFolderShortcuts declares the folders used often: the account's home folder and those
// opened over the connection before. Choosing one lists it.
func (a *App) remoteFolderShortcuts(c ui.C, language i18n.Language, b *remoteBrowser) {
	home := b.session.HomeDirectory
	type shortcut struct{ label, dir string }
	var shortcuts []shortcut
	if path.IsAbs(home) {
		shortcuts = append(shortcuts, shortcut{i18n.Shared(language, "desktop.remote.browse.home"), path.Clean(home)})
	}
	for _, folder := range b.recent {
		if dir, ok := remoteFolderPath(folder, home); ok {
			shortcuts = append(shortcuts, shortcut{remoteHomeRelative(dir, home), dir})
		}
	}
	if len(shortcuts) == 0 {
		return
	}
	ui.Row(c.Part("shortcuts")).FillWidth().Gap(6).Items(ui.Center).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.remote.browse.shortcuts")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		for i, item := range shortcuts {
			sc := c.Part("shortcut" + strconv.Itoa(i))
			if ui.Button(sc, item.label).Ghost().Small().Radius(12).Background(a.colors.Hover).Shrink(1).MinWidth(0).Tooltip(item.dir).Disabled(b.opening).Clicked() {
				dir := item.dir
				c.After(func() {
					a.performed("remote.browse.recent", surfaceButton)
					a.listRemoteFolder(dir)
				})
			}
		}
	})
}

// remoteHomeRelative writes dir under home with a leading ~.
func remoteHomeRelative(dir, home string) string {
	home = path.Clean(home)
	switch {
	case !path.IsAbs(home) || home == "/":
		return dir
	case dir == home:
		return "~"
	case strings.HasPrefix(dir, home+"/"):
		return "~" + dir[len(home):]
	}
	return dir
}

// remoteFolderCrumbs declares the path of the folder shown, a button for each folder above it.
func (a *App) remoteFolderCrumbs(c ui.C, b *remoteBrowser) {
	if b.dir == "" {
		return
	}
	parts := strings.Split(strings.Trim(b.dir, "/"), "/")
	if b.dir == "/" {
		parts = nil
	}
	ui.Row(c.Part("crumbs")).FillWidth().Gap(2).Items(ui.Center).Children(func() {
		crumb := func(i int, label, dir string) {
			if i == len(parts) {
				ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
				return
			}
			if ui.Button(c.Part("crumb"+strconv.Itoa(i)), label).Ghost().Small().Shrink(1).MinWidth(0).Disabled(b.opening).Clicked() {
				c.After(func() {
					a.performed("remote.browse.crumb", surfaceButton)
					a.listRemoteFolder(dir)
				})
			}
		}
		crumb(0, "/", "/")
		for i, part := range parts {
			ui.Icon(c, icons.ChevronRight).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
			crumb(i+1, part, "/"+strings.Join(parts[:i+1], "/"))
		}
	})
}

// remoteFolderUp declares the row that lists the parent of the folder shown.
func (a *App) remoteFolderUp(c ui.C, language i18n.Language, b *remoteBrowser) {
	label := i18n.Shared(language, "desktop.remote.browse.up")
	row := ui.Row(c).FillWidth().Height(30).Shrink(0).PadX(12).Gap(8).Items(ui.Center).
		Hit(ui.ID(c), label).Hover(ui.Look{}.Background(a.colors.Hover))
	row.Children(func() {
		ui.Icon(c, icons.ArrowUp).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
	if row.Clicked() && !b.opening {
		c.After(a.upRemoteFolder)
	}
}

// remoteFolderList declares the entries of the folder shown: its subfolders, then its files.
func (a *App) remoteFolderList(c ui.C, b *remoteBrowser) {
	language := a.language()
	title := i18n.Shared(language, "desktop.remote.browse.folders")
	count := len(b.folders) + len(b.files)
	if b.loading || count == 0 {
		text := i18n.Shared(language, "desktop.remote.browse.empty")
		switch {
		case b.loading:
			text = i18n.Shared(language, "native.loading")
		case b.readErr != "":
			text = ""
		}
		ui.Row(c.Part("empty")).FillWidth().Pad(12).Children(func() {
			ui.Paragraph(c, text, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
		return
	}
	hint := i18n.Shared(language, "desktop.remote.browse.enterHint")
	b.list.Label = func(row int) string {
		switch {
		case row >= 0 && row < len(b.folders):
			return b.folders[row]
		case row >= len(b.folders) && row < len(b.folders)+len(b.files):
			return b.files[row-len(b.folders)]
		}
		return ""
	}
	ui.List(c.Part("rows"), &b.list, count, func(row ui.ListRow) {
		rc := row.C
		row.Element.Height(remoteFolderRowHeight).PadX(12).Gap(10).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover))
		if row.Index >= len(b.folders) {
			name := b.files[row.Index-len(b.folders)]
			row.Element.Children(func() {
				ui.Icon(rc, icons.File).Size(15, 15).Shrink(0).Color(a.colors.Subtle.WithAlpha(0.7))
				ui.Text(rc, name).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			})
			return
		}
		name := b.folders[row.Index]
		row.Element.Children(func() {
			ui.Icon(rc, icons.Folder).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
			ui.Text(rc, name).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
			if b.repositories[name] {
				a.remoteTag(rc.Part("git"), i18n.Shared(language, "desktop.remote.browse.git"), a.colors.Subtle)
			}
			ui.Text(rc, hint).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		})
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
	if at, ok := b.list.Submitted(); ok && at >= 0 && at < len(b.folders) && !b.opening {
		dir := path.Join(b.dir, b.folders[at])
		c.After(func() {
			a.performed("remote.browse.enter", surfaceButton)
			a.listRemoteFolder(dir)
		})
	}
}

// remoteBrowserFooter declares Choose Later, which ends the session, and Open, naming the folder
// it opens.
func (a *App) remoteBrowserFooter(c ui.C, b *remoteBrowser) {
	language := a.language()
	if b.containers != nil {
		a.remoteHostContainersFooter(c, language, b.containers)
		return
	}
	ui.Spacer(c)
	if ui.Button(c.Part("back"), i18n.Shared(language, "desktop.remote.browse.back")).Outline().Disabled(b.opening).Clicked() {
		c.After(a.backFromRemoteBrowser)
	}
	label := i18n.Shared(language, "desktop.remote.browse.opening")
	if !b.opening {
		label = i18n.SharedFormat(language, "desktop.remote.browse.open", map[string]string{"name": path.Base(b.target())})
	}
	if ui.Button(c.Part("open"), label).Disabled(!b.openable()).Tooltip(b.target()).Clicked() {
		c.After(a.openRemoteFolder)
	}
}
