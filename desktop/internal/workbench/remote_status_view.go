package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A remote workspace names its host before the title bar's project selector. The icon shows the
// link state; the stable name does not grow as heartbeats and reconnect attempts come and go.
// Its menu reuses the connection window's source, discovery and connection flows.

// remoteStatusText is the item's text for r: the connection's name, with the round trip of the
// last heartbeat while connected or with how the connection is doing otherwise.
func remoteStatusText(language i18n.Language, r *remoteProject) string {
	switch r.link {
	case remoteUnresponsive:
		return i18n.SharedFormat(language, "desktop.remote.status.unresponsive", map[string]string{"kind": r.host.kind(language), "name": r.name})
	case remoteReconnecting:
		return i18n.SharedFormat(language, "desktop.remote.status.reconnecting", map[string]string{"kind": r.host.kind(language), "name": r.name})
	case remoteDisconnected:
		return i18n.SharedFormat(language, "desktop.remote.status.disconnected", map[string]string{"kind": r.host.kind(language), "name": r.name})
	}
	if r.latency <= 0 {
		return i18n.SharedFormat(language, "desktop.remote.status.connected", map[string]string{"kind": r.host.kind(language), "name": r.name})
	}
	ms := strconv.FormatInt(max(r.latency.Milliseconds(), 1), 10)
	return i18n.SharedFormat(language, "desktop.remote.status.latency", map[string]string{"kind": r.host.kind(language), "name": r.name, "ms": ms})
}

// remoteStatusLook is the icon of the item and its colour for r's link.
func (a *App) remoteStatusLook(r *remoteProject) (gfx.Icon, gfx.Color) {
	switch r.link {
	case remoteUnresponsive:
		return icons.CircleAlert, a.colors.Warning
	case remoteReconnecting:
		return icons.LoaderCircle, a.colors.Subtle
	case remoteDisconnected:
		return icons.Link2Off, a.theme.Danger
	}
	return icons.Link2, a.colors.Success
}

// remoteStatus declares the title bar's host selector, and nothing for a local project.
func (a *App) remoteStatus(c ui.C) {
	p := a.project
	if p == nil || p.remote == nil {
		if a.remote.hostsOnly {
			c.After(a.closeRemoteHostMenu)
		}
		return
	}
	r := p.remote
	language := a.language()
	text := remoteStatusText(language, r)
	details := strings.Join([]string{text, r.host.address(), r.remoteLocation()}, "\n")
	icon, color := a.remoteStatusLook(r)
	k := c.Part("remote")
	open := r.menuOpen
	button := ui.Row(k).Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeTitleGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), i18n.Shared(language, "desktop.remote.status.label"), gfx.HitOptions{
			Role:        gfx.RoleButton,
			Cursor:      gfx.PointerCursorHand,
			Value:       text,
			Description: details,
			Expandable:  true,
			Expanded:    open,
		}).Tooltip(details).TooltipOn(ui.TooltipBottom)
	if open {
		button = button.Background(a.colors.Hover)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		if r.link == remoteReconnecting {
			ui.Spinner(k).Size(chromeIconSize, chromeIconSize).Shrink(0)
		} else {
			ui.Icon(k, icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(color)
		}
		ui.Text(k, r.name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeBranchMax)
		ui.Icon(c, icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	clicked := button.Clicked()
	if open {
		a.remoteStatusMenu(k, p, button)
		if !r.menuOpen {
			c.After(a.closeRemoteHostMenu)
		}
	}
	if clicked && !open {
		c.After(a.openRemoteHostMenu)
	}
}

// remoteStatusMenu hangs below the host selector: the current link's details, available hosts,
// and the actions for reconnecting, choosing folders/files, closing and managing connections.
func (a *App) remoteStatusMenu(c ui.C, p *project, anchor ui.Box) {
	r := p.remote
	if !r.menuOpen {
		return
	}
	language := a.language()
	ui.Menu(c, anchor, &r.menuOpen, func(menu *ui.MenuItems) {
		menu.WidthRange(240, 560)
		icon, _ := a.remoteStatusLook(r)
		menu.Item(remoteStatusText(language, r)).Description(r.host.address()).Icon(icon).Disabled(true)
		menu.Label(r.remoteLocation())
		if r.failure != nil && r.link == remoteDisconnected {
			if text := remoteFailureText(language, r.failure); text != "" {
				menu.Item(text).Icon(icons.CircleX).Disabled(true)
			}
		}
		menu.Separator()
		menu.Label(i18n.Shared(language, "desktop.remote.hostSwitcher.switch"))
		a.remoteHostChoices(c, menu, r)
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.remote.hostSwitcher.chooseFolder")).Icon(icons.FolderOpen).Clicked() {
			target := remoteReopen{connectionID: r.connectionID, host: r.host, name: r.name}
			c.After(func() { a.chooseRemoteHost(target) })
		}
		if r.session == "" && r.reconnecting == nil {
			if menu.Item(i18n.Shared(language, "desktop.remote.status.reconnect")).Icon(icons.RefreshCw).Clicked() {
				c.After(func() { a.reconnectRemoteByUser(surfaceMenu) })
			}
		}
		if menu.Item(i18n.Shared(language, "desktop.remote.status.openHostFile")).Icon(icons.FolderOpen).Disabled(r.session == "").Clicked() {
			c.After(func() { a.openRemoteHostFiles(p, surfaceMenu) })
		}
		if menu.Item(i18n.Shared(language, "desktop.remote.status.disconnect")).Icon(icons.X).Clicked() {
			c.After(func() {
				a.performed("remote.workspace.disconnect", surfaceMenu)
				a.post(func(a *App) {
					if a.project == p {
						a.closeProject()
					}
				})
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.remote.menuItem")).Icon(icons.Server).Clicked() {
			c.After(func() { a.openRemote(surfaceMenu) })
		}
	})
}

// remoteHostChoices presents the same Core sections and discovered rows as the connection
// window. An SSH entry is reselected from the source before connecting, keeping edits current.
func (a *App) remoteHostChoices(c ui.C, menu *ui.MenuItems, current *remoteProject) {
	r := &a.remote
	language := a.language()
	if r.readErr != "" {
		menu.Item(r.readErr).Icon(icons.CircleAlert).Disabled(true)
	}
	if !r.loaded || !r.wsl.loaded || !r.containers.loaded {
		menu.Item(i18n.Shared(language, "native.loading")).Icon(icons.LoaderCircle).Disabled(true)
	}
	for _, row := range r.rows {
		if row.heading {
			menu.Label(remoteGroupHeading(language, row.group))
			continue
		}
		var target remoteReopen
		switch {
		case row.entry != nil:
			target = remoteReopen{connectionID: row.entry.ID, host: remoteHost{ssh: row.entry.Connection}, name: row.entry.Name}
		case row.wsl != "":
			wsl := core.WSLConnection{Distribution: row.wsl}
			target = remoteReopen{connectionID: wsl.Identity(), host: remoteHost{wsl: &wsl}, name: row.wsl}
		case row.container != nil:
			container := core.ContainerConnection{Engine: row.container.engine, Container: row.container.Name}
			target = remoteReopen{connectionID: container.Identity(), host: remoteHost{container: &container}, name: container.Container}
		}
		item := menu.Item(target.name).Description(target.host.address()).Icon(icons.Server).Chosen(target.connectionID == current.connectionID)
		if item.Clicked() {
			c.After(func() { a.switchRemoteHostRow(row) })
		}
	}
	if r.loaded && r.wsl.loaded && r.containers.loaded && len(r.rows) == 0 && r.readErr == "" {
		menu.Item(i18n.Shared(language, "desktop.remote.hostSwitcher.empty")).Disabled(true)
	}
}
