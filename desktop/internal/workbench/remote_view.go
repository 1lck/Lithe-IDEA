package workbench

import (
	"errors"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the Remote Development window of remote.go: the saved list on the left, and
// beside it the selected connection's overview or the form.

const (
	// remoteWindowWidth and remoteWindowHeight size the window: the list beside a form of two or
	// three fields a line.
	remoteWindowWidth  = 980
	remoteWindowHeight = 660
	// remoteListWidth is the width of the saved list.
	remoteListWidth = 264
	// remoteRowHeight is the height of a saved connection's row: its name over its address;
	// remoteHeadingHeight is the height of a group's heading.
	remoteRowHeight     = 44
	remoteHeadingHeight = 26
	// remoteSettingWidth is the width of the names in the overview's settings and host details.
	remoteSettingWidth = 150
	// remotePortWidth is the width of the port beside the host.
	remotePortWidth = 210
	// remoteSwatchSize is the size of a color choice.
	remoteSwatchSize = 22
)

// remoteColorChoices are the form's color choices in their order: none, then Core's colors.
var remoteColorChoices = append([]core.RemoteConnectionColor{""}, core.RemoteConnectionColors...)

// remoteGroupHeading is the heading of group in the list, "" being the connections without one.
func remoteGroupHeading(language i18n.Language, group string) string {
	switch group {
	case "":
		return i18n.Shared(language, "desktop.remote.ungrouped")
	case remoteWSLHeading:
		return i18n.Shared(language, "desktop.remote.wsl.heading")
	case remoteContainerHeading:
		return i18n.Shared(language, "desktop.remote.container.heading")
	}
	return group
}

// remoteColor is the color a connection is marked with in the light or dark look, false for none.
// The pairs are the ones the repository marks use, readable on either background.
func remoteColor(dark bool, color core.RemoteConnectionColor) (gfx.Color, bool) {
	switch color {
	case core.RemoteConnectionRed:
		return pick(dark, 0xE06C75, 0xC2353F), true
	case core.RemoteConnectionOrange:
		return pick(dark, 0xE5A04B, 0xC06A12), true
	case core.RemoteConnectionYellow:
		return pick(dark, 0xE5C07B, 0xB08800), true
	case core.RemoteConnectionGreen:
		return pick(dark, 0x5FAD65, 0x369650), true
	case core.RemoteConnectionBlue:
		return pick(dark, 0x4DA3E8, 0x1F6FD1), true
	case core.RemoteConnectionPurple:
		return pick(dark, 0xB589EC, 0x834DF0), true
	}
	return gfx.Color{}, false
}

// remoteColorName names color, one of remoteColorChoices.
func remoteColorName(language i18n.Language, color core.RemoteConnectionColor) string {
	switch color {
	case core.RemoteConnectionRed:
		return i18n.Shared(language, "desktop.remote.color.red")
	case core.RemoteConnectionOrange:
		return i18n.Shared(language, "desktop.remote.color.orange")
	case core.RemoteConnectionYellow:
		return i18n.Shared(language, "desktop.remote.color.yellow")
	case core.RemoteConnectionGreen:
		return i18n.Shared(language, "desktop.remote.color.green")
	case core.RemoteConnectionBlue:
		return i18n.Shared(language, "desktop.remote.color.blue")
	case core.RemoteConnectionPurple:
		return i18n.Shared(language, "desktop.remote.color.purple")
	}
	return i18n.Shared(language, "desktop.remote.color.none")
}

// remoteAddress is a connection as OpenSSH would address it: [user@]host[:port].
func remoteAddress(connection core.SSHConnection) string {
	address := connection.Host
	if connection.User != "" {
		address = connection.User + "@" + address
	}
	if connection.Port != 0 {
		host := address
		if strings.Contains(connection.Host, ":") {
			// An IPv6 address keeps its brackets apart from the port.
			host = strings.TrimSuffix(address, connection.Host) + "[" + connection.Host + "]"
		}
		address = host + ":" + strconv.Itoa(int(connection.Port))
	}
	return address
}

// remoteFields declares the form: two or three fields a line, each under its label, with the
// advanced options folded below.
func (a *App) remoteFields(c ui.C) {
	r := &a.remote
	f := &r.form
	language := a.language()
	disabled := r.saving
	effective := a.remoteFormEffective()
	text := func(k ui.C, label, placeholder string, field *ui.Field) {
		ui.TextField(k, field, label, placeholder).FillWidth().MinWidth(0).Disabled(disabled)
	}
	line := func(key string, cells func(ui.C)) {
		k := c.Part(key)
		ui.Row(k).FillWidth().Gap(14).Items(ui.Start).Children(func() { cells(k) })
	}
	ui.Column(c).FillWidth().Gap(14).Children(func() {
		line("line-name", func(k ui.C) {
			label := i18n.Shared(language, "desktop.remote.name")
			a.remoteCell(k.Part("name"), "name", label, "", 0, func(k ui.C) {
				text(k, label, i18n.Shared(language, "desktop.remote.namePlaceholder"), &f.name)
			})
			a.remoteCell(k.Part("color"), "", i18n.Shared(language, "desktop.remote.color"), i18n.Shared(language, "desktop.remote.colorHelp"), -1, func(k ui.C) {
				a.remoteSwatches(k, language, disabled)
			})
		})
		line("line-host", func(k ui.C) {
			label := i18n.Shared(language, "desktop.remote.host")
			a.remoteCell(k.Part("host"), "host", label, i18n.Shared(language, "desktop.remote.hostHelp"), 0, func(k ui.C) {
				text(k, label, i18n.Shared(language, "desktop.remote.hostPlaceholder"), &f.host)
			})
			label = i18n.Shared(language, "desktop.remote.port")
			a.remoteCell(k.Part("port"), "port", label, "", remotePortWidth, func(k ui.C) {
				text(k, label, a.remoteAutoPlaceholder(language, effective.port, i18n.Shared(language, "desktop.remote.portPlaceholder")), &f.port)
			})
		})
		line("line-user", func(k ui.C) {
			label := i18n.Shared(language, "desktop.remote.user")
			a.remoteCell(k.Part("user"), "user", label, "", 0, func(k ui.C) {
				text(k, label, a.remoteAutoPlaceholder(language, effective.user, i18n.Shared(language, "desktop.remote.userPlaceholder")), &f.user)
			})
			authLabel := i18n.Shared(language, "desktop.remote.authentication")
			a.remoteCell(k.Part("authentication"), "authentication", authLabel, i18n.Shared(language, "desktop.remote.authenticationHelp"), 0, func(k ui.C) {
				ui.Select(k, &f.authentication, remoteAuthentications, func(way string) string {
					return remoteAuthenticationLabel(language, way)
				}).Label(authLabel).FillWidth().MinWidth(0).Disabled(disabled)
			})
			if f.authentication != core.RemoteAuthenticationPrivateKey {
				// The line keeps three columns, so that the fields line up with the key's.
				ui.Row(k.Part("identityFile-space")).Grow(1).Basis(0)
				return
			}
			label = i18n.Shared(language, "desktop.remote.identityFile")
			a.remoteCell(k.Part("identityFile"), "identityFile", label, i18n.Shared(language, "desktop.remote.identityFileHelp"), 0, func(k ui.C) {
				box := ui.TextField(k, &f.identityFile, label, i18n.Shared(language, "desktop.remote.identityFilePlaceholder")).FillWidth().MinWidth(0).Disabled(disabled).
					Action(icons.FolderOpen, i18n.Shared(language, "desktop.remote.choose"))
				if box.ActionClicked() {
					c.After(a.chooseRemoteIdentity)
				}
			})
		})
		line("line-group", func(k ui.C) { a.remoteGroupCells(k, language, disabled) })
		line("line-jump", func(k ui.C) {
			label := i18n.Shared(language, "desktop.remote.proxyJump")
			a.remoteCell(k.Part("proxyJump"), "proxyJump", label, i18n.Shared(language, "desktop.remote.proxyJumpHelp"), 0, func(k ui.C) {
				a.remoteHops(k, language, disabled)
			})
		})
		// The advanced options fold under a line; folded, the header says what they are now, so
		// the form need not open to show them.
		timeout := a.remoteAutoPlaceholder(language, effective.timeout, i18n.Shared(language, "desktop.remote.timeoutPlaceholder"))
		keepAlive := a.remoteAutoPlaceholder(language, effective.keepAlive, i18n.Shared(language, "desktop.remote.keepAlivePlaceholder"))
		ui.Row(c.Part("advanced-line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		head := c.Part("advanced")
		ui.Row(head).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			icon := icons.ChevronRight
			if f.advanced.Open {
				icon = icons.ChevronDown
			}
			if ui.Button(head.Part("fold"), i18n.Shared(language, "desktop.remote.advanced")).Icon(icon).Ghost().Shrink(0).Clicked() {
				c.After(func() { f.advanced.Open = !f.advanced.Open })
			}
			if !f.advanced.Open {
				ui.Text(head, i18n.SharedFormat(language, "desktop.remote.advancedSummary", map[string]string{
					"timeout":   remoteSecondsOr(language, f.timeout.Text(), timeout),
					"keepAlive": remoteSecondsOr(language, f.keepAlive.Text(), keepAlive),
				})).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
			}
		})
		if f.advanced.Open {
			k := c.Part("advanced-fields")
			ui.Column(k).FillWidth().Gap(14).PadTop(4).Children(func() {
				ui.Row(k.Part("line-timing")).FillWidth().Gap(14).Items(ui.Start).Children(func() {
					label := i18n.Shared(language, "desktop.remote.timeout")
					a.remoteCell(k.Part("connectTimeoutSeconds"), "connectTimeoutSeconds", label, "", 0, func(k ui.C) {
						text(k, label, timeout, &f.timeout)
					})
					label = i18n.Shared(language, "desktop.remote.keepAlive")
					a.remoteCell(k.Part("keepAliveSeconds"), "keepAliveSeconds", label, i18n.Shared(language, "desktop.remote.keepAliveHelp"), 0, func(k ui.C) {
						text(k, label, keepAlive, &f.keepAlive)
					})
				})
			})
		}
	})
}

// remoteSecondsOr is a typed number of seconds as "N seconds", or fallback when the field is empty.
func remoteSecondsOr(language i18n.Language, typed, fallback string) string {
	if typed = strings.TrimSpace(typed); typed != "" {
		return i18n.SharedFormat(language, "desktop.remote.seconds", map[string]string{"count": typed})
	}
	return fallback
}

// remoteSwatches declares the color choices: none, then Core's colors, as one stop of Tab that
// the arrows move through.
func (a *App) remoteSwatches(c ui.C, language i18n.Language, disabled bool) {
	f := &a.remote.form
	ui.Row(c).MinHeight(a.theme.Metrics.ControlHeight).Gap(8).Items(ui.Center).FocusGroup(ui.FocusHorizontal).Children(func() {
		for index, choice := range remoteColorChoices {
			color, _ := remoteColor(a.colors.Dark, choice)
			chosen := f.color == choice
			name := remoteColorName(language, choice)
			swatch := ui.ColorSwatch(c.KeyInt(index), color, chosen, name).Size(remoteSwatchSize, remoteSwatchSize).TabStop(chosen).
				Disabled(disabled).Tooltip(name)
			if swatch.Clicked() {
				c.After(func() { f.color = choice })
			}
		}
	})
}

// remoteGroupCells declares the group choice: none, the list's groups and a new one, whose name is
// typed in the field beside it.
func (a *App) remoteGroupCells(c ui.C, language i18n.Language, disabled bool) {
	r := &a.remote
	f := &r.form
	label := i18n.Shared(language, "desktop.remote.group")
	choices := make([]string, 0, len(r.groups)+2)
	choices = append(append(append(choices, ""), r.groups...), remoteNewGroup)
	typing := f.group == remoteNewGroup
	refused := "group"
	if typing {
		refused = ""
	}
	a.remoteCell(c.Part("group"), refused, label, i18n.Shared(language, "desktop.remote.groupHelp"), 0, func(k ui.C) {
		ui.Select(k, &f.group, choices, func(group string) string {
			switch group {
			case "":
				return i18n.Shared(language, "desktop.remote.group.none")
			case remoteNewGroup:
				return i18n.Shared(language, "desktop.remote.group.new")
			}
			return group
		}).Label(label).FillWidth().MinWidth(0).Disabled(disabled)
	})
	if !typing {
		ui.Row(c.Part("newGroup-space")).Grow(1).Basis(0)
		return
	}
	name := i18n.Shared(language, "desktop.remote.groupPlaceholder")
	a.remoteCell(c.Part("newGroup"), "group", name, "", 0, func(k ui.C) {
		ui.TextField(k, &f.newGroup, name, name).FillWidth().MinWidth(0).Disabled(disabled).AutoFocus()
	})
}

// remoteAuthenticationLabel names way, one of remoteAuthentications.
func remoteAuthenticationLabel(language i18n.Language, way string) string {
	switch way {
	case core.RemoteAuthenticationAgent:
		return i18n.Shared(language, "desktop.remote.auth.agent")
	case core.RemoteAuthenticationPrivateKey:
		return i18n.Shared(language, "desktop.remote.auth.privateKey")
	case core.RemoteAuthenticationPassword:
		return i18n.Shared(language, "desktop.remote.auth.password")
	}
	return i18n.Shared(language, "desktop.remote.auth.auto")
}

// remoteCell declares one field of the form: its label and ⓘ over its control, and under it the
// reason Core refused field ("" for a control Core never refuses). width is the cell's width: 0
// shares the line's width with the other cells, -1 takes what the control needs.
func (a *App) remoteCell(c ui.C, field, label, help string, width float32, control func(ui.C)) {
	r := &a.remote
	cell := ui.Column(c).Gap(6).MinWidth(0)
	switch {
	case width > 0:
		cell.Width(width).Shrink(0)
	case width == 0:
		cell.Grow(1).Basis(0)
	default:
		cell.Shrink(0)
	}
	cell.Children(func() {
		ui.Row(c.Part("label")).FillWidth().Height(18).Items(ui.Center).Gap(4).Children(func() {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightMedium).Ellipsis().Shrink(1).MinWidth(0)
			if help != "" {
				a.remoteHelp(c, help)
			}
		})
		control(c)
		if field != "" && r.fieldErr.field == field {
			ui.Paragraph(c, remoteRefusalText(a.language(), r.fieldErr), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	})
}

// remoteHelp declares an ⓘ whose tip is help.
func (a *App) remoteHelp(c ui.C, help string) {
	ui.Button(c.Part("help"), i18n.Shared(a.language(), "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().
		Size(18, 18).Shrink(0).Tooltip(help).TooltipOn(ui.TooltipRight)
}

// remoteNotice declares a line with an icon in color.
func (a *App) remoteNotice(c ui.C, icon gfx.Icon, color gfx.Color, text string) {
	ui.Row(c).FillWidth().Gap(8).Items(ui.Start).Children(func() {
		ui.Icon(c, icon).Size(16, 16).Shrink(0).Color(color)
		ui.Paragraph(c, text, 6).Color(color).Grow(1).MinWidth(0)
	})
}

// remoteFailureText says why outcome did not connect, and is "" when it connected. The Remote
// Development window shows it under the host, and the status bar's menu for the last attempt to
// connect a workspace again.
func remoteFailureText(language i18n.Language, outcome *remoteProbeOutcome) string {
	if err := outcome.err; err != nil {
		if own := remoteConnectFailureText(language, err); own != "" {
			return own
		}
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeRuntimeMissing {
			// What is missing is a program of this computer: the engine's CLI only for a container
			// of this computer, and wsl.exe or OpenSSH for one on a host.
			switch {
			case outcome.engine != "" && !outcome.hosted:
				return i18n.SharedFormat(language, "desktop.remote.container.missing", map[string]string{"engine": remoteContainerEngineName(language, outcome.engine)})
			case outcome.wsl:
				return i18n.Shared(language, "desktop.remote.wsl.missing")
			}
			return i18n.Shared(language, "desktop.remote.probe.noSSH")
		}
		return i18n.SharedFormat(language, "desktop.remote.probe.error", map[string]string{"reason": remoteLogError(err).Error()})
	}
	result := outcome.result
	switch result.Status {
	case core.RemoteProbeConnected:
		return ""
	case core.RemoteProbeUnsupportedPlatform:
		var system, machine string
		if host := result.Host; host != nil {
			system, machine = host.System, host.Machine
		}
		return i18n.SharedFormat(language, "desktop.remote.probe.unsupported", map[string]string{"system": system, "machine": machine})
	case core.RemoteProbeAuthenticationFailed:
		return i18n.Shared(language, "desktop.remote.probe.authenticationFailed")
	case core.RemoteProbeHostKeyRejected:
		return i18n.Shared(language, "desktop.remote.probe.hostKeyRejected")
	case core.RemoteProbeUnreachable:
		switch {
		case outcome.hosted:
			// Core answers the same for a host it cannot reach and a container that is gone there;
			// the diagnostics under the text say which.
			return i18n.SharedFormat(language, "desktop.remote.container.hostUnreachable", map[string]string{"engine": remoteContainerEngineName(language, outcome.engine)})
		case outcome.engine != "":
			return i18n.Shared(language, "desktop.remote.container.unreachable")
		case outcome.wsl:
			return i18n.Shared(language, "desktop.remote.wsl.unreachable")
		}
		return i18n.Shared(language, "desktop.remote.probe.unreachable")
	}
	return i18n.Shared(language, "desktop.remote.probe.failed")
}
