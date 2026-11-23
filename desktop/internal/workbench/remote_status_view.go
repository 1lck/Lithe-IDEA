package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the status bar's item of a remote workspace (remote_workspace.go): the
// connection and how it is doing, as the button that opens the connection's menu. It sits at the
// leading end of the status bar, as the remote indicator of VS Code and of JetBrains Gateway does.

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
		return icons.CircleX, a.theme.Danger
	}
	return icons.Server, a.colors.Success
}

// remoteStatus declares the item of the open remote workspace, and nothing for a local project.
func (a *App) remoteStatus(c ui.C) {
	p := a.project
	if p == nil || p.remote == nil {
		return
	}
	r := p.remote
	language := a.language()
	text := remoteStatusText(language, r)
	icon, color := a.remoteStatusLook(r)
	k := c.Part("remote")
	button := ui.Row(k).Height(chromeStatusItem).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeStatusPad).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), i18n.Shared(language, "desktop.remote.status.label"), gfx.HitOptions{
			Role:       gfx.RoleButton,
			Cursor:     gfx.PointerCursorHand,
			Value:      text,
			Expandable: true,
			Expanded:   r.menuOpen,
		})
	if r.menuOpen {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		ui.Icon(c, icon).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(color)
		a.chromeStatusLabel(k, text)
		ui.Icon(c, icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	if button.Clicked() && !r.menuOpen {
		r.menuOpen = true
	}
	a.remoteStatusMenu(k, p, button)
}

// remoteStatusMenu declares the open menu of the connection above anchor: the host folder, why
// connecting again failed, Reconnect while there is no session, Open File on Host while there
// is one, Disconnect, which closes the workspace, and the Remote Development window.
func (a *App) remoteStatusMenu(c ui.C, p *project, anchor ui.Box) {
	r := p.remote
	if !r.menuOpen {
		return
	}
	language := a.language()
	ui.Menu(c, anchor, &r.menuOpen, func(menu *ui.MenuItems) {
		menu.Above()
		// Wide enough for why connecting again failed, which the menu shows on one line.
		menu.WidthRange(240, 560)
		menu.Label(r.remoteLocation())
		if r.failure != nil && r.link == remoteDisconnected {
			if text := remoteFailureText(language, r.failure); text != "" {
				menu.Item(text).Icon(icons.CircleX).Disabled(true)
			}
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
