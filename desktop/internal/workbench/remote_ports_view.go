package workbench

import (
	"net"
	"strconv"
	"strings"
	"unicode/utf8"

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
	remotePortsRemoteWidth = 200
	remotePortsLabelWidth  = 120
	remotePortsLocalWidth  = 150
	remotePortsSourceWidth = 90
	remotePortsStatusWidth = 170
	remotePortsActionWidth = 96
)

// remotePortsActions declares the Ports window's header actions: the security note of forwards
// (S30), Add Forwarding Rule and Stop All Forwards.
func (a *App) remotePortsActions(c ui.C, p *project) {
	r := p.remote
	if r == nil {
		return
	}
	language := a.language()
	ui.Button(c.Part("ports-help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
		Tooltip(i18n.Shared(language, "desktop.remote.ports.help"))
	if _, clicked := a.toolIconButton(c.Part("ports-rule-add"), i18n.Shared(language, "desktop.remote.ports.ruleAdd"), icons.Plus, false, r.session == ""); clicked {
		c.After(func() { a.openRemotePortRule(p, nil, surfaceToolbar) })
	}
	disabled := r.session == "" || len(r.ports.forwards) == 0 || r.ports.stoppingAll
	if _, clicked := a.toolIconButton(c.Part("ports-stop-all"), i18n.Shared(language, "desktop.remote.ports.stopAll"), icons.Square, false, disabled); clicked {
		c.After(func() { a.stopAllRemotePorts(p, surfaceToolbar) })
	}
}

// remotePortsView declares the body of the Ports window: the field a port is typed into, the
// window's message, the list of ports and the forwarding rules, running or remembered.
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
		switch ports.addRefused {
		case "":
		case "credentials":
			a.remotePortsLine(c.Part("add-invalid"), i18n.Shared(language, "desktop.remote.ports.addCredentials"), a.theme.Danger)
		default:
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
		rows, rules, idle := ports.rows(), ports.rules(), ports.idleRules()
		empty := i18n.Shared(language, "desktop.remote.ports.empty")
		if !ports.listed && ports.readFailed == "" {
			empty = i18n.Shared(language, "desktop.remote.ports.loading")
		}
		if len(rows) == 0 && len(rules) == 0 && len(idle) == 0 {
			a.panelMessage(c, empty, a.colors.Subtle)
			return
		}
		if len(rows) > 0 {
			a.remotePortsHeader(c)
		}
		ui.Scroll(c.Part("ports-list")).Scrollbars().Fill().Children(func() {
			if len(rows) == 0 {
				a.remotePortsLine(c.Part("ports-empty"), empty, a.colors.Subtle)
			}
			for _, row := range rows {
				a.remotePortsRow(c.Key("port:"+row.key.host+":"+strconv.Itoa(int(row.key.port))), p, row)
			}
			if len(rules) > 0 || len(idle) > 0 {
				a.remotePortRules(c, p, rules, idle)
			}
		})
	})
	a.remotePortsConfirm(c, p)
	a.remotePortsLocal(c, p)
	a.remotePortsLabel(c, p)
	a.remotePortRuleDialog(c, p)
}

// remotePortsLine declares a line of the window's messages in color.
func (a *App) remotePortsLine(c ui.C, text string, color gfx.Color) {
	ui.Row(c).FillWidth().Shrink(0).PadX(shellContentPad).PadY(4).Children(func() {
		ui.Paragraph(c, text, 3).Grow(1).Color(color)
	})
}

// remotePortsAddRow declares the field a port, host:port or URL is typed into and the button that
// forwards it.
func (a *App) remotePortsAddRow(c ui.C, p *project) {
	ports := &p.remote.ports
	language := a.language()
	k := c.Part("ports-add")
	ui.Row(k).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		submitted := ui.TextField(k.Part("field"), &ports.add, i18n.Shared(language, "desktop.remote.ports.addLabel"),
			i18n.Shared(language, "desktop.remote.ports.addPlaceholder")).Grow(1).Submitted()
		unavailable := p.remote.session == "" || ports.adding
		add := ui.Button(k.Part("button"), i18n.Shared(language, "desktop.remote.ports.add")).Outline().
			Disabled(unavailable || strings.TrimSpace(ports.add.Text()) == "")
		if (submitted || add.Clicked()) && !unavailable {
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
				ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		}
		column("remote", i18n.Shared(language, "desktop.remote.ports.columnRemote"), remotePortsRemoteWidth)
		column("label", i18n.Shared(language, "desktop.remote.ports.columnLabel"), remotePortsLabelWidth)
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

// remotePortsRemoteFits is the most characters of the Remote Port column that its width shows
// whole; a longer text, such as a URL, a global IPv6 address or a long host name, ends in an
// ellipsis, so its tooltip gives it whole.
const remotePortsRemoteFits = 24

// remotePortsRemote is the Remote Port column of row and its tooltip. The column reads the URL the
// user added the port as; otherwise the first address the host listens on for it, IPv4 first,
// with the count of the others; otherwise the address the user typed or the forward's target.
// The tooltip gives what the column cuts off or leaves out: the URL with every address the host
// listens on for its port, every address of a port the host listens on more than once, or a text
// longer than the column shows whole. It is "" when the column says everything.
func remotePortsRemote(language i18n.Language, row remotePortRow) (text, tip string) {
	port := strconv.Itoa(int(row.key.port))
	addresses := row.addresses()
	switch {
	case row.url():
		text = row.added.scheme + "://" + net.JoinHostPort(row.added.host, port) + row.added.path
	case len(addresses) > 1:
		text = i18n.SharedFormat(language, "desktop.remote.ports.remoteMore",
			map[string]string{"address": addresses[0], "count": strconv.Itoa(len(addresses) - 1)})
	case len(addresses) == 1:
		text = addresses[0]
	default:
		text = net.JoinHostPort(row.target(), port)
	}
	listening := strings.Join(addresses, ", ")
	switch {
	case row.url() && len(addresses) > 0:
		tip = i18n.SharedFormat(language, "desktop.remote.ports.remoteUrlListening", map[string]string{"url": text, "addresses": listening})
	case len(addresses) > 1:
		tip = i18n.SharedFormat(language, "desktop.remote.ports.remoteListening", map[string]string{"addresses": listening})
	case utf8.RuneCountInString(text) > remotePortsRemoteFits:
		tip = text
	}
	return text, tip
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
	remote, remoteTip := remotePortsRemote(language, row)
	line := ui.Row(c).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).
		Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(c), remote, gfx.HitOptions{Value: status, SkipFocus: true})
	line.Children(func() {
		remoteCell := ui.Row(c.Part("remote")).Width(remotePortsRemoteWidth).Shrink(0).Items(ui.Center)
		if remoteTip != "" {
			// The cell takes an identity for its tooltip, which gives what the column cuts off or
			// leaves out.
			remoteCell = remoteCell.HitWith(ui.ID(c.Part("remote")), remoteTip, gfx.HitOptions{Role: gfx.RoleStatus, SkipFocus: true}).
				Tooltip(remoteTip)
		}
		remoteCell.Children(func() {
			ui.Text(c, remote).Color(a.colors.Text).Ellipsis()
		})
		a.remotePortsLabelCell(c, ports.labels[row.key])
		localCell := ui.Row(c.Part("local")).Width(remotePortsLocalWidth).Shrink(0).Items(ui.Center)
		color := a.colors.Text
		if localTip != "" {
			// The cell takes an identity for its tooltip, which says why the port differs.
			color = a.colors.Warning
			localCell = localCell.HitWith(ui.ID(c.Part("local")), local, gfx.HitOptions{Role: gfx.RoleStatus, Value: localTip, SkipFocus: true}).
				Tooltip(localTip)
		}
		localCell.Children(func() {
			ui.Text(c, local).Color(color).Ellipsis()
		})
		ui.Row(c.Part("process")).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			ui.Text(c, remotePortsProcess(language, row)).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("source")).Width(remotePortsSourceWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c, source).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("status")).Width(remotePortsStatusWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c, status).Color(statusColor).Ellipsis()
		})
		ui.Row(c.Part("actions")).Width(remotePortsActionWidth).Shrink(0).Items(ui.Center).Justify(ui.End).Gap(2).Children(func() {
			a.remotePortsRowActions(c, p, row, busy)
		})
	})
	ui.ContextMenu(c, line, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if row.forward != nil {
			forward := *row.forward
			if _, browsable := row.browserURL(); browsable {
				if menu.Item(i18n.Shared(language, "desktop.remote.ports.openBrowser")).Icon(icons.ExternalLink).Clicked() {
					c.After(func() { a.openRemotePort(row, surfaceContextMenu) })
				}
			}
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.copyAddress")).Icon(icons.Copy).Clicked() {
				c.After(func() { a.copyRemotePort(row, surfaceContextMenu) })
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
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.editLabel")).Icon(icons.Tag).Clicked() {
			key := row.key
			c.After(func() { a.editRemotePortLabel(p, remotePortLabelTarget{key: &key}, surfaceContextMenu) })
		}
		if row.added != nil && row.forward == nil && len(row.listening) == 0 {
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.remove")).Icon(icons.Trash2).Disabled(busy).Clicked() {
				c.After(func() { a.removeRemotePort(p, row.key) })
			}
		}
	})
}

// remotePortsRowActions declares the buttons at the end of row: Open in Browser — unless the row's
// URL is not one a browser opens — Copy Local Address and Stop Forwarding for a forwarded port,
// Forward otherwise.
func (a *App) remotePortsRowActions(c ui.C, p *project, row remotePortRow, busy bool) {
	language := a.language()
	if row.forward == nil {
		if _, clicked := a.toolIconButton(c.Part("forward"), i18n.Shared(language, "desktop.remote.ports.forward"), icons.ArrowLeftRight, false, busy || p.remote.session == ""); clicked {
			c.After(func() { a.forwardRemotePort(p, row.key, row.target(), false, surfaceButton) })
		}
		return
	}
	forward := *row.forward
	if _, browsable := row.browserURL(); browsable {
		if _, clicked := a.toolIconButton(c.Part("open"), i18n.Shared(language, "desktop.remote.ports.openBrowser"), icons.ExternalLink, false, false); clicked {
			c.After(func() { a.openRemotePort(row, surfaceButton) })
		}
	}
	if _, clicked := a.toolIconButton(c.Part("copy"), i18n.Shared(language, "desktop.remote.ports.copyAddress"), icons.Copy, false, false); clicked {
		c.After(func() { a.copyRemotePort(row, surfaceButton) })
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
	closed := ui.Modal(c.Part("ports-confirm"), &ports.confirmOpen, i18n.Shared(language, "desktop.remote.ports.confirmTitle"), ui.ModalSpec{}, func() {
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
	row, _ := ports.row(*ports.local)
	remote, _ := remotePortsRemote(language, row)
	closed := ui.Modal(c.Part("ports-local"), &ports.localOpen, i18n.Shared(language, "desktop.remote.ports.localTitle"), ui.ModalSpec{}, func() {
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

// remotePortsLabelFits is the most characters of the Label column that its width shows whole.
const remotePortsLabelFits = 14

// remotePortsLabelCell declares the Label column of a row or a rule: the name the user gave it.
func (a *App) remotePortsLabelCell(c ui.C, label string) {
	cell := ui.Row(c.Part("label")).Width(remotePortsLabelWidth).Shrink(0).Items(ui.Center)
	if utf8.RuneCountInString(label) > remotePortsLabelFits {
		// The cell takes an identity for its tooltip, which gives the label the column cuts off.
		cell = cell.HitWith(ui.ID(c.Part("label")), label, gfx.HitOptions{Role: gfx.RoleStatus, SkipFocus: true}).Tooltip(label)
	}
	cell.Children(func() {
		ui.Text(c, label).Color(a.colors.Text).Ellipsis()
	})
}

// remotePortsLabel declares the dialog the label of a row or a rule is typed in. Closing it
// changes nothing.
func (a *App) remotePortsLabel(c ui.C, p *project) {
	ports := &p.remote.ports
	if ports.label == nil {
		ports.labelOpen = false
		return
	}
	language := a.language()
	closed := ui.Modal(c.Part("ports-label"), &ports.labelOpen, i18n.Shared(language, "desktop.remote.ports.labelTitle"), ui.ModalSpec{}, func() {
		ui.Paragraph(c, i18n.Shared(language, "desktop.remote.ports.labelBody"), 5).Color(a.colors.Text)
		submitted := ui.TextField(c.Part("ports-label-field"), &ports.labelField, i18n.Shared(language, "desktop.remote.ports.labelField"),
			i18n.Shared(language, "desktop.remote.ports.labelField")).FillWidth().Submitted()
		if ports.labelInvalid {
			ui.Text(c, i18n.Shared(language, "desktop.remote.ports.labelInvalid")).FontSize(12).Color(a.theme.Danger)
		}
		if submitted {
			c.After(func() { a.applyRemotePortLabel(p) })
		}
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.labelCancel")).Outline().Clicked() {
			ports.labelOpen = false
		}
		if ui.Button(c, i18n.Shared(language, "desktop.remote.ports.labelApply")).Clicked() {
			c.After(func() { a.applyRemotePortLabel(p) })
		}
	})
	if closed || !ports.labelOpen {
		ports.label, ports.labelOpen, ports.labelInvalid = nil, false, false
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
		ui.Icon(c, icons.ArrowLeftRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Accent)
		a.chromeStatusLabel(k, count)
	})
	if button.Clicked() {
		c.After(func() {
			a.performed("remote.ports.status", surfaceButton)
			a.openToolWindow(itemPorts)
		})
	}
}
