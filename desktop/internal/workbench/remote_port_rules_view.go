package workbench

import (
	"net"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the forwarding rules of the Ports window (remote_port_rules.go): their list
// below the ports and the Add Forwarding Rule dialog.

const (
	// The widths of the rule list's fixed columns; the Forwards To column takes the rest.
	remotePortRulesListenWidth      = 200
	remotePortRulesConnectionsWidth = 150
)

// remotePortRules declares the list of the session's host and reverse rules, then the rules the
// window remembers that are not running.
func (a *App) remotePortRules(c ui.C, p *project, rules []core.RemoteForward, idle []core.RemotePortRule) {
	language := a.language()
	k := c.Part("rules")
	ui.Row(k.Part("heading")).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(shellContentPad).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.remote.ports.rulesHeading")).Color(a.colors.Text).Ellipsis()
		ui.Button(k.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(16, 16).
			Tooltip(i18n.Shared(language, "desktop.remote.ports.rulesHelp"))
	})
	ui.Row(k.Part("header")).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).Children(func() {
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
		column("listen", i18n.Shared(language, "desktop.remote.ports.ruleColumnListen"), remotePortRulesListenWidth)
		column("label", i18n.Shared(language, "desktop.remote.ports.columnLabel"), remotePortsLabelWidth)
		column("target", i18n.Shared(language, "desktop.remote.ports.ruleColumnTarget"), 0)
		column("connections", i18n.Shared(language, "desktop.remote.ports.ruleColumnConnections"), remotePortRulesConnectionsWidth)
		column("status", i18n.Shared(language, "desktop.remote.ports.columnStatus"), remotePortsStatusWidth)
		ui.Row(k.Part("actions")).Width(remotePortsActionWidth).Shrink(0)
	})
	ui.Divider(c)
	for _, rule := range rules {
		a.remotePortRuleRow(c.Key("rule:"+strconv.FormatUint(rule.ID, 10)), p, rule)
	}
	for _, rule := range idle {
		a.remotePortIdleRuleRow(c.Key("idle:"+remotePortIdleKey(rule)), p, rule)
	}
}

// remotePortIdleKey names a remembered rule among the list's rows.
func remotePortIdleKey(rule core.RemotePortRule) string {
	return string(rule.Kind) + ":" + strconv.Itoa(int(rule.ListenPort)) + ":" + rule.TargetHost + ":" +
		strconv.Itoa(int(rule.TargetPort)) + ":" + strconv.Itoa(int(rule.LocalPort))
}

// remotePortIdleListen is the Host Listens On column of a remembered rule: the host's loopback
// address with its port, as a running rule lists it (a remembered rule never listens on every
// interface), or that the host chooses a port.
func remotePortIdleListen(language i18n.Language, rule core.RemotePortRule) string {
	if rule.ListenPort == 0 {
		return i18n.Shared(language, "desktop.remote.ports.ruleListenAny")
	}
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(int(rule.ListenPort)))
}

// remotePortIdleTarget is the Forwards To column of a remembered rule.
func remotePortIdleTarget(language i18n.Language, rule core.RemotePortRule) string {
	if rule.Kind == core.RemoteForwardReverse {
		return i18n.SharedFormat(language, "desktop.remote.ports.ruleThisComputer",
			map[string]string{"address": net.JoinHostPort("127.0.0.1", strconv.Itoa(int(rule.LocalPort)))})
	}
	return net.JoinHostPort(rule.TargetHost, strconv.Itoa(int(rule.TargetPort)))
}

// remotePortIdleRuleRow declares a remembered rule that is not running, its Start and Forget
// buttons and its context menu. Start opens Add Forwarding Rule filled in with it, so the rule
// starts only once the user adds it there.
func (a *App) remotePortIdleRuleRow(c ui.C, p *project, rule core.RemotePortRule) {
	r := p.remote
	language := a.language()
	listen := remotePortIdleListen(language, rule)
	status := i18n.Shared(language, "desktop.remote.ports.statusNotRunning")
	unavailable := r.session == "" || r.ports.stoppingAll
	icon := icons.Server
	if rule.Kind == core.RemoteForwardReverse {
		icon = icons.Monitor
	}
	line := ui.Row(c).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).
		Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(c), listen, gfx.HitOptions{Value: status, SkipFocus: true})
	line.Children(func() {
		ui.Row(c.Part("listen")).Width(remotePortRulesListenWidth).Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, listen).Color(a.colors.Subtle).Ellipsis()
		})
		a.remotePortsLabelCell(c, rule.Label)
		ui.Row(c.Part("target")).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			ui.Text(c, remotePortIdleTarget(language, rule)).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("connections")).Width(remotePortRulesConnectionsWidth).Shrink(0)
		ui.Row(c.Part("status")).Width(remotePortsStatusWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c, status).Color(a.colors.Subtle).Ellipsis()
		})
		ui.Row(c.Part("actions")).Width(remotePortsActionWidth).Shrink(0).Items(ui.Center).Justify(ui.End).Gap(2).Children(func() {
			if _, clicked := a.toolIconButton(c.Part("start"), i18n.Shared(language, "desktop.remote.ports.ruleStart"), icons.Play, false, unavailable); clicked {
				c.After(func() { a.startRememberedRule(p, rule, surfaceButton) })
			}
			if _, clicked := a.toolIconButton(c.Part("forget"), i18n.Shared(language, "desktop.remote.ports.ruleForget"), icons.Trash2, false, false); clicked {
				c.After(func() { a.forgetRemotePortRule(p, rule, surfaceButton) })
			}
		})
	})
	ui.ContextMenu(c, line, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.ruleStart")).Icon(icons.Play).Disabled(unavailable).Clicked() {
			c.After(func() { a.startRememberedRule(p, rule, surfaceContextMenu) })
		}
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.editLabel")).Icon(icons.Tag).Clicked() {
			c.After(func() { a.editRemotePortLabel(p, remotePortLabelTarget{rule: &rule}, surfaceContextMenu) })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.ruleForget")).Icon(icons.Trash2).Clicked() {
			c.After(func() { a.forgetRemotePortRule(p, rule, surfaceContextMenu) })
		}
	})
}

// remotePortRuleStatus is the Status column of rule and its colour.
func (a *App) remotePortRuleStatus(ports *remotePorts, rule core.RemoteForward) (string, gfx.Color) {
	language := a.language()
	if ports.ruleStopping[rule.ID] {
		return i18n.Shared(language, "desktop.remote.ports.statusStopping"), a.colors.Subtle
	}
	if reason := ports.ruleFailed[rule.ID]; reason != "" {
		return i18n.SharedFormat(language, "desktop.remote.ports.statusFailed", map[string]string{"reason": reason}), a.theme.Danger
	}
	return i18n.Shared(language, "desktop.remote.ports.statusForwarded"), a.colors.Success
}

// remotePortRuleRow declares one rule of the list, its Stop button and its context menu. A rule
// that listens on every interface of the host reads in the warning colour.
func (a *App) remotePortRuleRow(c ui.C, p *project, rule core.RemoteForward) {
	r := p.remote
	ports := &r.ports
	language := a.language()
	busy := ports.ruleStopping[rule.ID] || ports.stoppingAll
	listen := remotePortRuleListenAddress(rule)
	status, statusColor := a.remotePortRuleStatus(ports, rule)
	connections := strconv.FormatUint(rule.Connections, 10)
	connectionsColor := a.colors.Subtle
	if rule.FailedConnections > 0 {
		connections = i18n.SharedFormat(language, "desktop.remote.ports.ruleConnectionsFailed", map[string]string{
			"count": connections, "failed": strconv.FormatUint(rule.FailedConnections, 10),
		})
		connectionsColor = a.colors.Warning
	}
	icon := icons.Server
	if rule.Kind == core.RemoteForwardReverse {
		icon = icons.Monitor
	}
	line := ui.Row(c).FillWidth().Height(remotePortsRowHeight).Shrink(0).Items(ui.Center).PadX(shellContentPad).
		Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(c), listen, gfx.HitOptions{Value: status, SkipFocus: true})
	line.Children(func() {
		listenCell := ui.Row(c.Part("listen")).Width(remotePortRulesListenWidth).Shrink(0).Items(ui.Center).Gap(6)
		color := a.colors.Text
		if rule.AllInterfaces {
			// The cell takes an identity for its tooltip, which says who can reach the port.
			color = a.colors.Warning
			tip := i18n.Shared(language, "desktop.remote.ports.ruleAllInterfacesTip")
			listenCell = listenCell.HitWith(ui.ID(c.Part("listen")), listen, gfx.HitOptions{Role: gfx.RoleStatus, Value: tip, SkipFocus: true}).
				Tooltip(tip)
		}
		listenCell.Children(func() {
			ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(color)
			ui.Text(c, listen).Color(color).Ellipsis()
		})
		a.remotePortsLabelCell(c, ports.ruleLabel(rule))
		ui.Row(c.Part("target")).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			ui.Text(c, remotePortRuleTarget(language, rule)).Color(a.colors.Text).Ellipsis()
		})
		ui.Row(c.Part("connections")).Width(remotePortRulesConnectionsWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c, connections).Color(connectionsColor).Ellipsis()
		})
		ui.Row(c.Part("status")).Width(remotePortsStatusWidth).Shrink(0).Items(ui.Center).Children(func() {
			ui.Text(c, status).Color(statusColor).Ellipsis()
		})
		ui.Row(c.Part("actions")).Width(remotePortsActionWidth).Shrink(0).Items(ui.Center).Justify(ui.End).Gap(2).Children(func() {
			if _, clicked := a.toolIconButton(c.Part("stop"), i18n.Shared(language, "desktop.remote.ports.stop"), icons.Square, false, busy); clicked {
				c.After(func() { a.stopRemotePortRule(p, rule.ID, surfaceButton) })
			}
		})
	})
	ui.ContextMenu(c, line, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		record := remotePortRuleOf(rule)
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.editLabel")).Icon(icons.Tag).Clicked() {
			c.After(func() { a.editRemotePortLabel(p, remotePortLabelTarget{rule: &record}, surfaceContextMenu) })
		}
		if _, remembered := ports.rememberedRule(record); remembered {
			if menu.Item(i18n.Shared(language, "desktop.remote.ports.ruleForget")).Icon(icons.Trash2).Clicked() {
				c.After(func() { a.forgetRemotePortRule(p, record, surfaceContextMenu) })
			}
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.remote.ports.stop")).Icon(icons.Square).Disabled(busy).Clicked() {
			c.After(func() { a.stopRemotePortRule(p, rule.ID, surfaceContextMenu) })
		}
	})
}

// remotePortRuleDialog declares the Add Forwarding Rule dialog: its fields, or the question the
// rule waits for in their place. Closing it starts nothing.
func (a *App) remotePortRuleDialog(c ui.C, p *project) {
	ports := &p.remote.ports
	draft := ports.rule
	if draft == nil {
		ports.ruleOpen = false
		return
	}
	language := a.language()
	title := i18n.Shared(language, "desktop.remote.ports.ruleTitle")
	switch draft.confirm {
	case remotePortRuleConfirmAll:
		title = i18n.Shared(language, "desktop.remote.ports.ruleConfirmAllTitle")
	case remotePortRuleConfirmTarget:
		title = i18n.Shared(language, "desktop.remote.ports.confirmTitle")
	case remotePortRuleConfirmReverse:
		title = i18n.Shared(language, "desktop.remote.ports.ruleConfirmReverseTitle")
	}
	unavailable := p.remote.session == "" || draft.starting
	closed := ui.Modal(c.Part("ports-rule"), &ports.ruleOpen, title, ui.ModalSpec{}, func() {
		if draft.confirm != remotePortRuleNoConfirm {
			ui.Paragraph(c, a.remotePortRuleQuestion(p, draft), 6).Color(a.colors.Warning)
			return
		}
		a.remotePortRuleFields(c, p, draft, unavailable)
	}, func() {
		if draft.confirm != remotePortRuleNoConfirm {
			if ui.Button(c.Part("rule-back"), i18n.Shared(language, "desktop.remote.ports.ruleBack")).Outline().Clicked() {
				c.After(func() { a.declineRemotePortRule(p) })
			}
			if ui.Button(c.Part("rule-confirm"), i18n.Shared(language, "desktop.remote.ports.ruleConfirm")).Disabled(unavailable).Clicked() {
				c.After(func() { a.confirmRemotePortRule(p, surfaceButton) })
			}
			return
		}
		if ui.Button(c.Part("rule-cancel"), i18n.Shared(language, "desktop.remote.ports.ruleCancel")).Outline().Clicked() {
			ports.ruleOpen = false
		}
		empty := strings.TrimSpace(draft.target.Text()) == ""
		if ui.Button(c.Part("rule-submit"), i18n.Shared(language, "desktop.remote.ports.ruleSubmit")).Disabled(unavailable || empty).Clicked() {
			c.After(func() { a.submitRemotePortRule(p, surfaceButton) })
		}
	})
	if closed || !ports.ruleOpen {
		if draft.confirm != remotePortRuleNoConfirm {
			a.operationRejected("remote_port_rule", remotePortRuleDeclined(draft.confirm))
		}
		ports.rule, ports.ruleOpen = nil, false
	}
}

// remotePortRuleFields declares the dialog's fields: the direction, the host port, what the rule
// reaches and, for a host rule, the choice to listen on every interface of the host.
func (a *App) remotePortRuleFields(c ui.C, p *project, draft *remotePortRuleDraft, unavailable bool) {
	language := a.language()
	kinds := []remotePortRuleKind{remotePortRuleHost}
	// A remembered reverse rule is shown as one while the preferences are read.
	if draft.reverseAllowed || draft.kind == remotePortRuleReverse {
		kinds = append(kinds, remotePortRuleReverse)
	}
	kindLabel := func(kind remotePortRuleKind) string {
		if kind == remotePortRuleReverse {
			return i18n.Shared(language, "desktop.remote.ports.ruleKindReverse")
		}
		return i18n.Shared(language, "desktop.remote.ports.ruleKindHost")
	}
	kindTitle := i18n.Shared(language, "desktop.remote.ports.ruleKind")
	ui.Text(c, kindTitle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	if ui.Select(c.Part("rule-kind"), &draft.kind, kinds, kindLabel).FillWidth().Label(kindTitle).Disabled(unavailable).Changed() {
		draft.message = ""
		draft.target.SetText("")
	}
	if !draft.reverseAllowed {
		ui.Paragraph(c, i18n.Shared(language, "desktop.remote.ports.ruleReverseOff"), 3).
			FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	}
	reverse := draft.kind == remotePortRuleReverse
	note := i18n.SharedFormat(language, "desktop.remote.ports.ruleHostNote", map[string]string{"name": p.remote.name})
	targetTitle := i18n.Shared(language, "desktop.remote.ports.ruleTarget")
	targetPlaceholder := i18n.Shared(language, "desktop.remote.ports.ruleTargetPlaceholder")
	if reverse {
		note = i18n.SharedFormat(language, "desktop.remote.ports.ruleReverseNote", map[string]string{"name": p.remote.name})
		targetTitle = i18n.Shared(language, "desktop.remote.ports.ruleLocal")
		targetPlaceholder = i18n.Shared(language, "desktop.remote.ports.ruleLocalPlaceholder")
	}
	ui.Paragraph(c, note, 4).Color(a.colors.Text)
	listenTitle := i18n.Shared(language, "desktop.remote.ports.ruleListen")
	ui.Text(c, listenTitle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	listened := ui.TextField(c.Part("rule-listen"), &draft.listen, listenTitle,
		i18n.Shared(language, "desktop.remote.ports.ruleListenPlaceholder")).FillWidth().Submitted()
	ui.Text(c, targetTitle).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	targeted := ui.TextField(c.Part("rule-target"), &draft.target, targetTitle, targetPlaceholder).FillWidth().Submitted()
	if !reverse {
		ui.Checkbox(c.Part("rule-all"), &draft.allInterfaces, i18n.Shared(language, "desktop.remote.ports.ruleAllInterfaces")).Disabled(unavailable)
		if draft.allInterfaces {
			ui.Paragraph(c, i18n.Shared(language, "desktop.remote.ports.ruleAllInterfacesNote"), 3).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
		}
	}
	if draft.starting {
		ui.Text(c, i18n.Shared(language, "desktop.remote.ports.statusForwarding")).FontSize(12).Color(a.colors.Subtle)
	}
	if draft.message != "" {
		ui.Paragraph(c, draft.message, 3).FontSize(12).Color(a.theme.Danger)
	}
	if (listened || targeted) && !unavailable {
		c.After(func() { a.submitRemotePortRule(p, surfaceShortcut) })
	}
}

// remotePortRuleQuestion is the question the dialog's rule waits for.
func (a *App) remotePortRuleQuestion(p *project, draft *remotePortRuleDraft) string {
	language := a.language()
	listen := func(port uint16) string {
		if port == 0 {
			return i18n.Shared(language, "desktop.remote.ports.ruleListenAny")
		}
		return i18n.SharedFormat(language, "desktop.remote.ports.ruleListenPort", map[string]string{"port": strconv.Itoa(int(port))})
	}
	target := net.JoinHostPort(draft.host.Host, strconv.Itoa(int(draft.host.Port)))
	name := p.remote.name
	switch draft.confirm {
	case remotePortRuleConfirmAll:
		return i18n.SharedFormat(language, "desktop.remote.ports.ruleConfirmAll",
			map[string]string{"name": name, "listen": listen(draft.host.ListenPort), "target": target})
	case remotePortRuleConfirmTarget:
		return i18n.SharedFormat(language, "desktop.remote.ports.ruleConfirmTarget", map[string]string{"name": name, "target": target})
	}
	return i18n.SharedFormat(language, "desktop.remote.ports.ruleConfirmReverse", map[string]string{
		"name": name, "local": strconv.Itoa(int(draft.reverse.LocalPort)), "listen": listen(draft.reverse.ListenPort),
	})
}
