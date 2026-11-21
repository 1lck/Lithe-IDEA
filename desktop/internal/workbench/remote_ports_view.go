package workbench

import (
	"net"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the Ports tool window of a remote workspace (remote_ports.go) and the status
// bar's count of its forwards.

const (
	// remotePortsRowHeight is the height of a row of the list and of its header.
	remotePortsRowHeight = 26
	// The widths of the list's fixed columns; the Process column takes the rest.
	remotePortsRemoteWidth = 150
	remotePortsLocalWidth  = 150
	remotePortsSourceWidth = 90
	remotePortsStatusWidth = 170
	remotePortsActionWidth = 96
)

// remotePortsActions declares the Ports window's header actions: the security note of forwards
// (S30) and Stop All Forwards.
func (a *App) remotePortsActions(c ui.C, p *project) {
	r := p.remote
	if r == nil {
		return
	}
	language := a.language()
	ui.Button(c.Part("ports-help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
		Tooltip(i18n.Shared(language, "desktop.remote.ports.help"))
	disabled := r.session == "" || len(r.ports.forwards) == 0 || r.ports.stoppingAll
	if _, clicked := a.toolIconButton(c.Part("ports-stop-all"), i18n.Shared(language, "desktop.remote.ports.stopAll"), icons.Square, false, disabled); clicked {
		c.After(func() { a.stopAllRemotePorts(p, surfaceToolbar) })
	}
}

// remotePortsView declares the body of the Ports window: the field a port is typed into, the
// window's message, and the list of ports.
func (a *App) remotePortsView(c ui.C, p *project) {
	r := p.remote
	if r == nil {
		a.toolPlaceholder(c)
		return
	}
	a.showRemotePorts(p)
	ports := &r.ports
	language := a.language()
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.remotePortsAddRow(c, p)
		if ports.addInvalid {
			a.remotePortsLine(c.Part("add-invalid"), i18n.Shared(language, "desktop.remote.ports.addInvalid"), a.theme.Danger)
		}
		if ports.notice != "" {
			a.remotePortsLine(c.Part("notice"), ports.notice, a.colors.Warning)
		}
		ui.Divider(c)
		if r.session == "" {
			a.panelMessage(c, i18n.Shared(language, "desktop.remote.ports.disconnected"), a.colors.Subtle)
			return
		}
		if ports.readFailed != "" {
			a.remotePortsLine(c.Part("read-failed"), i18n.SharedFormat(language, "desktop.remote.ports.readFailed",
				map[string]string{"reason": ports.readFailed}), a.theme.Danger)
		}
		rows := ports.rows()
		if len(rows) == 0 {
			if !ports.listed && ports.readFailed == "" {
				a.panelMessage(c, i18n.Shared(language, "desktop.remote.ports.loading"), a.colors.Subtle)
			} else {
				a.panelMessage(c, i18n.Shared(language, "desktop.remote.ports.empty"), a.colors.Subtle)
			}
			return
		}
		a.remotePortsHeader(c)
		ui.Scroll(c.Part("ports-list")).Scrollbars().Fill().Children(func() {
			for _, row := range rows {
				a.remotePortsRow(c.Key("port:"+row.key.host+":"+strconv.Itoa(int(row.key.port))), p, row)
			}
		})
	})
	a.remotePortsConfirm(c, p)
	a.remotePortsLocal(c, p)
}

// remotePortsLine declares a line of the window's messages in color.
func (a *App) remotePortsLine(c ui.C, text string, color gfx.Color) {
	ui.Row(c).FillWidth().Shrink(0).PadX(shellContentPad).PadY(4).Children(func() {
		ui.Paragraph(c, text, 3).Grow(1).Color(color)
	})
}

// remotePortsAddRow declares the field a port is typed into and the button that forwards it.
func (a *App) remotePortsAddRow(c ui.C, p *project) {
	ports := &p.remote.ports
	language := a.language()
	k := c.Part("ports-add")
	ui.Row(k).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		submitted := ui.TextField(k.Part("field"), &ports.add, i18n.Shared(language, "desktop.remote.ports.addLabel"),
			i18n.Shared(language, "desktop.remote.ports.addPlaceholder")).Grow(1).Submitted()
		add := ui.Button(k.Part("button"), i18n.Shared(language, "desktop.remote.ports.add")).Outline().
			Disabled(p.remote.session == "" || strings.TrimSpace(ports.add.Text()) == "")
		if (submitted || add.Clicked()) && p.remote.session != "" {
			surface := surfaceButton
			if submitted {
				surface = surfaceShortcut
			}
			c.After(func() { a.addRemotePort(p, surface) })
		}
	})
}

// remotePortsHeader declares the header of the list.
func (a *App) remotePortsHeader(c ui.C) {
	language := a.language()
	k := c.Part("ports-header")
	ui.Row(k).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).Children(func() {
		column := func(key, text string, width float32) {
			cell := ui.Row(k.Part(key)).Shrink(0).Items(ui.Center)
			if width > 0 {
				cell = cell.Width(width)
			} else {
				cell = cell.Grow(1).Shrink(1).MinWidth(0)
			}
			cell.Children(func() {
				ui.Text(k.Part(key+"-text"), text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		}
		column("remote", i18n.Shared(language, "desktop.remote.ports.columnRemote"), remotePortsRemoteWidth)
		column("local", i18n.Shared(language, "desktop.remote.ports.columnLocal"), remotePortsLocalWidth)
		column("process", i18n.Shared(language, "desktop.remote.ports.columnProcess"), 0)
		column("source", i18n.Shared(language, "desktop.remote.ports.columnSource"), remotePortsSourceWidth)
		column("status", i18n.Shared(language, "desktop.remote.ports.columnStatus"), remotePortsStatusWidth)
		ui.Row(k.Part("actions")).Width(remotePortsActionWidth).Shrink(0)
	})
	ui.Divider(c)
}

// remotePortsProcess is the Process column of row: the command name and process ID of each
// listening process the host named, or Unknown.
func remotePortsProcess(language i18n.Language, row remotePortRow) string {
	var names []string
	seen := map[uint32]bool{}
	for _, port := range row.listening {
		if port.PID == 0 || seen[port.PID] {
			continue
		}
		seen[port.PID] = true
		names = append(names, i18n.SharedFormat(language, "desktop.remote.ports.process",
			map[string]string{"process": port.Process, "pid": strconv.FormatUint(uint64(port.PID), 10)}))
	}
	if len(names) == 0 {
		if len(row.listening) == 0 {
			return ""
		}
		return i18n.Shared(language, "desktop.remote.ports.processUnknown")
	}
	return strings.Join(names, ", ")
}

// remotePortsRemote is the Remote Port column of row: the port, after the address it is bound to
// when that is not the host's loopback interface.
func remotePortsRemote(row remotePortRow) string {
	port := strconv.Itoa(int(row.key.port))
	if row.key.host == "" {
		return port
	}
	return net.JoinHostPort(row.key.host, port)
}

// remotePortsStatus is the Status column of row and its colour.
func (a *App) remotePortsStatus(ports *remotePorts, row remotePortRow) (string, gfx.Color) {
	language := a.language()
	switch ports.busy[row.key] {
	case remotePortForwarding:
		return i18n.Shared(language, "desktop.remote.ports.statusForwarding"), a.colors.Subtle
	case remotePortStopping:
		return i18n.Shared(language, "desktop.remote.ports.statusStopping"), a.colors.Subtle
	}
	if reason := ports.failed[row.key]; reason != "" {
		return i18n.SharedFormat(language, "desktop.remote.ports.statusFailed", map[string]string{"reason": reason}), a.theme.Danger
	}
	if row.forward != nil {
		return i18n.Shared(language, "desktop.remote.ports.statusForwarded"), a.colors.Success
	}
	return i18n.Shared(language, "desktop.remote.ports.statusNotForwarded"), a.colors.Subtle
}

// remotePortsRow declares one row of the list, its actions and its context menu.
func (a *App) remotePortsRow(c ui.C, p *project, row remotePortRow) {
	r := p.remote
	ports := &r.ports
	language := a.language()
	busy := ports.busy[row.key] != 0 || ports.stoppingAll
	status, statusColor := a.remotePortsStatus(ports, row)
	source := i18n.Shared(language, "desktop.remote.ports.sourceManual")
	if len(row.listening) > 0 {
		source = i18n.Shared(language, "desktop.remote.ports.sourceListening")
	}
	local := ""
	localTip := ""
	if row.forward != nil {
		local = remotePortAddress(*row.forward)
		if row.forward.LocalPortChanged && row.forward.RequestedLocalPort != nil {
			localTip = i18n.SharedFormat(language, "desktop.remote.ports.localChanged", map[string]string{
				"requested": strconv.Itoa(int(*row.forward.RequestedLocalPort)),
				"port":      strconv.Itoa(int(row.forward.LocalPort)),
			})
		}
	}
	line := ui.Row(c).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).
		Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(c), remotePortsRemote(row), gfx.HitOptions{Value: status, SkipFocus: true})
	line.Children(func() {
		ui.Row(c.Part("remote")).Width(remotePortsRemoteWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c.Part("remote-text"), remotePortsRemote(row)).Color(a.colors.Text).Ellipsis()
		})
		localCell := ui.Row(c.Part("local")).Width(remotePortsLocalWidth).Shrink(0).Items(ui.Center)
		color := a.colors.Text
		if localTip != "" {
			// The cell takes an identity for its tooltip, which says why the port differs.
			color = a.colors.Warning
			localCell = localCell.HitWith(ui.ID(c.Part("local")), local, gfx.HitOptions{Role: gfx.RoleStatus, Value: localTip, SkipFocus: true}).
				Tooltip(localTip)
		}
		localCell.Children(func() {
			ui.Text(c.Part("local-text"), local).Color(color).Ellipsis()
		})
		ui.Row(c.Part("process")).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			ui.Text(c.Part("process-text"), remotePortsProcess(language, row)).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("source")).Width(remotePortsSourceWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c.Part("source-text"), source).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("status")).Width(remotePortsStatusWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c.Part("status-text"), status).Color(statusColor).Ellipsis()
		})
		ui.Row(c.Part("actions")).Width(remotePortsActionWidth).Shrink(0).Items(ui.Center).Justify(ui.End).Gap(2).Children(func() {
			a.remotePortsRowActions(c, p, row, busy)
		})
	})
	ui.ContextMenu(c.Part("menu"), line, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if row.forward != nil {
			forward := *row.forward
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.openBrowser")).Icon(icons.ExternalLink).Clicked() {
				c.After(func() { a.openRemotePort(forward, surfaceContextMenu) })
			}
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.copyAddress")).Icon(icons.Copy).Clicked() {
				c.After(func() { a.copyRemotePort(forward, surfaceContextMenu) })
			}
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.changeLocal")).Icon(icons.Pencil).Disabled(busy || r.session == "").Clicked() {
				c.After(func() { a.chooseRemoteLocalPort(p, row.key, surfaceContextMenu) })
			}
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.stop")).Icon(icons.Square).Disabled(busy).Clicked() {
				c.After(func() { a.stopRemotePort(p, row.key, forward.ID, surfaceContextMenu) })
			}
		} else {
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.forward")).Icon(icons.ArrowLeftRight).Disabled(busy || r.session == "").Clicked() {
				c.After(func() { a.forwardRemotePort(p, row.key, row.target(), false, surfaceContextMenu) })
			}
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.forwardLocal")).Icon(icons.Pencil).Disabled(busy || r.session == "").Clicked() {
				c.After(func() { a.chooseRemoteLocalPort(p, row.key, surfaceContextMenu) })
			}
		}
		if row.manual && row.forward == nil && len(row.listening) == 0 {
			menu.Separator()
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.remove")).Icon(icons.Trash2).Disabled(busy).Clicked() {
				c.After(func() { a.removeRemotePort(p, row.key) })
			}
		}
	})
}

// remotePortsRowActions declares the buttons at the end of row: Open in Browser, Copy Local Address
// and Stop Forwarding for a forwarded port, Forward otherwise.
func (a *App) remotePortsRowActions(c ui.C, p *project, row remotePortRow, busy bool) {
	language := a.language()
	if row.forward == nil {
		if _, clicked := a.toolIconButton(c.Part("forward"), i18n.Shared(language, "desktop.remote.ports.forward"), icons.ArrowLeftRight, false, busy || p.remote.session == ""); clicked {
			c.After(func() { a.forwardRemotePort(p, row.key, row.target(), false, surfaceButton) })
		}
		return
	}
	forward := *row.forward
	if _, clicked := a.toolIconButton(c.Part("open"), i18n.Shared(language, "desktop.remote.ports.openBrowser"), icons.ExternalLink, false, false); clicked {
		c.After(func() { a.openRemotePort(forward, surfaceButton) })
	}
	if _, clicked := a.toolIconButton(c.Part("copy"), i18n.Shared(language, "desktop.remote.ports.copyAddress"), icons.Copy, false, false); clicked {
		c.After(func() { a.copyRemotePort(forward, surfaceButton) })
	}
	if _, clicked := a.toolIconButton(c.Part("stop"), i18n.Shared(language, "desktop.remote.ports.stop"), icons.Square, false, busy); clicked {
		c.After(func() { a.stopRemotePort(p, row.key, forward.ID, surfaceButton) })
	}
}

// remotePortsConfirm declares the question a forward to a target outside the host's loopback
// interface waits for (S28). Closing it is a refusal.
func (a *App) remotePortsConfirm(c ui.C, p *project) {
	ports := &p.remote.ports
	if ports.confirm == nil {
		ports.confirmOpen = false
		return
	}
	language := a.language()
	pending := *ports.confirm
	target := net.JoinHostPort(pending.host, strconv.Itoa(int(pending.key.port)))
	closed := ui.Modal(c.Part("ports-confirm"), &ports.confirmOpen, i18n.Shared(language, "desktop.remote.ports.confirmTitle"), func() {
		ui.Paragraph(c, i18n.SharedFormat(language, "desktop.remote.ports.confirmBody",
			map[string]string{"target": target, "name": p.remote.name}), 5).Color(a.colors.Warning)
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.confirmCancel")).Outline().Clicked() {
			ports.confirmOpen = false
		}
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.confirmForward")).Clicked() {
			c.After(func() { a.confirmRemotePort(p) })
		}
	})
	if closed || !ports.confirmOpen {
		if ports.confirm != nil {
			a.operationRejected("remote_port_forward", "target_declined")
		}
		ports.confirm, ports.confirmOpen = nil, false
	}
}

// remotePortsLocal declares the dialog the local port of a row is chosen in. Closing it changes
// nothing.
func (a *App) remotePortsLocal(c ui.C, p *project) {
	ports := &p.remote.ports
	if ports.local == nil {
		ports.localOpen = false
		return
	}
	language := a.language()
	remote := remotePortsRemote(remotePortRow{key: *ports.local})
	closed := ui.Modal(c.Part("ports-local"), &ports.localOpen, i18n.Shared(language, "desktop.remote.ports.localTitle"), func() {
		ui.Paragraph(c, i18n.SharedFormat(language, "desktop.remote.ports.localBody",
			map[string]string{"remote": remote, "name": p.remote.name}), 5).Color(a.colors.Text)
		submitted := ui.TextField(c.Part("ports-local-field"), &ports.localField, i18n.Shared(language, "desktop.remote.ports.localLabel"),
			i18n.Shared(language, "desktop.remote.ports.localLabel")).FillWidth().Submitted()
		if ports.localInvalid {
			ui.Text(c, i18n.Shared(language, "desktop.remote.ports.localInvalid")).FontSize(12).Color(a.theme.Danger)
		}
		if submitted {
			c.After(func() { a.applyRemoteLocalPort(p) })
		}
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.localCancel")).Outline().Clicked() {
			ports.localOpen = false
		}
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.localApply")).Clicked() {
			c.After(func() { a.applyRemoteLocalPort(p) })
		}
	})
	if closed || !ports.localOpen {
		ports.local, ports.localOpen, ports.localInvalid = nil, false, false
	}
}

// remotePortsStatusItem declares the status bar's count of the forwards of the open remote
// workspace, next to its connection, while it forwards a port. A click opens the Ports window.
func (a *App) remotePortsStatusItem(c ui.C) {
	p := a.project
	if p == nil || p.remote == nil || len(p.remote.ports.forwards) == 0 {
		return
	}
	language := a.language()
	count := strconv.Itoa(len(p.remote.ports.forwards))
	k := c.Part("remote-ports")
	button := ui.Row(k).Height(chromeStatusItem).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeStatusPad).
		Radius(a.theme.Metrics.RadiusItem()).
		Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(k), i18n.Shared(language, "desktop.remote.ports.statusLabel"), gfx.HitOptions{
			Role:   gfx.RoleButton,
			Cursor: gfx.PointerCursorHand,
			Value:  count,
		}).
		Tooltip(i18n.SharedFormat(language, "desktop.remote.ports.statusTooltip", map[string]string{"count": count}))
	button.Children(func() {
		ui.Icon(k, icons.ArrowLeftRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Accent)
		a.chromeStatusLabel(k, count)
	})
	if button.Clicked() {
		c.After(func() {
			a.performed("remote.ports.status", surfaceButton)
			a.openToolWindow(itemPorts)
		})
	}
}
