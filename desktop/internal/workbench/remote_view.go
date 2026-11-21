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

// This file draws the Remote Development window of remote.go.

const (
	// remoteWindowWidth and remoteWindowHeight size the window: the list beside a form whose
	// labels and fields stay on one line each.
	remoteWindowWidth  = 820
	remoteWindowHeight = 580
	// remoteListWidth is the width of the saved list.
	remoteListWidth = 240
	// remoteLabelWidth is the width of the form's label column.
	remoteLabelWidth = 132
	// remoteRowHeight is the height of a saved connection's row: its name over its address.
	remoteRowHeight = 44
)

// remoteView declares the window while it is open. Escape, the scrim and the close button end it
// like Close.
func (a *App) remoteView(c ui.C) {
	r := &a.remote
	if !r.open {
		return
	}
	language := a.language()
	open := true
	ui.ModalWith(c, &open, i18n.Shared(language, "desktop.remote.title"), ui.ModalSpec{Width: remoteWindowWidth, Height: remoteWindowHeight}, func() {
		k := c.Part("remote")
		ui.Row(k).Fill().Children(func() {
			a.remoteList(k)
			ui.Column(k).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
			a.remoteDetail(k)
		})
	}, func() {
		a.remoteFooter(c.Part("remote-footer"))
	})
	if !open {
		c.After(a.closeRemote)
	}
}

// remoteList declares the saved connections, under a header with the button that starts a new one.
func (a *App) remoteList(c ui.C) {
	r := &a.remote
	language := a.language()
	k := c.Part("list")
	title := i18n.Shared(language, "desktop.remote.saved")
	ui.Column(k).Width(remoteListWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(k.Part("header")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(4).PadSides(0, 6, 0, 10).Children(func() {
			ui.Text(k, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			if path := r.source.Path(); path != "" {
				a.remoteHelp(k.Part("storage"), i18n.SharedFormat(language, "desktop.remote.storageHelp", map[string]string{"path": path}))
			}
			ui.Spacer(k)
			if a.gitIconButton(k.Part("new"), i18n.Shared(language, "desktop.remote.new"), icons.Plus, false, r.saving) {
				c.After(func() {
					a.performed("remote.connection.new", surfaceButton)
					r.selectNew()
				})
			}
		})
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		connections := r.source.Connections
		if len(connections) == 0 {
			text := i18n.Shared(language, "desktop.remote.empty")
			if r.loading {
				text = i18n.Shared(language, "native.loading")
			}
			ui.Row(k.Part("empty")).FillWidth().Pad(10).Children(func() {
				ui.Paragraph(k, text, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			})
			return
		}
		r.list.Label = func(row int) string {
			if row < 0 || row >= len(r.source.Connections) {
				return ""
			}
			return r.source.Connections[row].Name
		}
		ui.List(k.Part("rows"), &r.list, len(connections), func(row ui.ListRow) {
			entry := connections[row.Index]
			rc := row.C
			row.Element.Height(remoteRowHeight).PadX(10).Gap(8).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover))
			// The row of the edited connection is highlighted, also in the frame a save added it,
			// before the list's own selection can reach it.
			if entry.ID == r.selected {
				row.Element.Background(a.colors.Selection)
			}
			row.Element.Children(func() {
				ui.Icon(rc, icons.Server).Size(16, 16).Shrink(0).Color(a.colors.Subtle)
				ui.Column(rc).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
					ui.Text(rc, entry.Name).Weight(gfx.WeightSemibold).Ellipsis()
					ui.Text(rc, remoteAddress(entry.Connection)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
				})
			})
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
		if r.list.Changed() {
			if at := r.list.Selected(); at >= 0 && at < len(connections) && connections[at].ID != r.selected {
				id := connections[at].ID
				c.After(func() {
					a.performed("remote.connection.select", surfaceButton)
					r.selectEntry(id)
				})
			}
		} else {
			// The list selects only rows it has declared, so the row a save added becomes the
			// keyboard's row here, once the list declared it.
			r.syncListSelection()
		}
	})
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

// remoteDetail declares the form of the edited connection, then what the last test found.
func (a *App) remoteDetail(c ui.C) {
	r := &a.remote
	language := a.language()
	k := c.Part("detail")
	ui.Scroll(k).Scrollbars().Grow(1).FillHeight().MinWidth(0).Children(func() {
		ui.Column(k.Part("form")).FillWidth().Pad(16).Gap(10).Children(func() {
			if r.readErr != "" {
				a.remoteNotice(k.Part("read"), icons.CircleAlert, a.theme.Danger, r.readErr)
			}
			a.remoteFields(k)
			if r.err != "" {
				ui.Paragraph(k.Part("error"), r.err, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			a.remoteResult(k.Part("result"), language)
		})
	})
}

// remoteFields declares the connection's fields, each a row of its label and control, with the
// reason a refused one was refused under it.
func (a *App) remoteFields(c ui.C) {
	r := &a.remote
	f := &r.form
	language := a.language()
	disabled := r.saving
	text := func(key, label, placeholder, help string, field *ui.Field) {
		a.remoteRow(c.Part(key), key, label, help, func(k ui.C) {
			ui.TextField(k, field, label, placeholder).Grow(1).MinWidth(0).Disabled(disabled)
		})
	}
	text("name", i18n.Shared(language, "desktop.remote.name"), i18n.Shared(language, "desktop.remote.namePlaceholder"), "", &f.name)
	text("host", i18n.Shared(language, "desktop.remote.host"), i18n.Shared(language, "desktop.remote.hostPlaceholder"), i18n.Shared(language, "desktop.remote.hostHelp"), &f.host)
	text("port", i18n.Shared(language, "desktop.remote.port"), i18n.Shared(language, "desktop.remote.portPlaceholder"), "", &f.port)
	text("user", i18n.Shared(language, "desktop.remote.user"), i18n.Shared(language, "desktop.remote.userPlaceholder"), "", &f.user)
	authLabel := i18n.Shared(language, "desktop.remote.authentication")
	a.remoteRow(c.Part("authentication"), "authentication", authLabel, i18n.Shared(language, "desktop.remote.authenticationHelp"), func(k ui.C) {
		ui.Select(k, &f.authentication, remoteAuthentications, func(way string) string {
			return remoteAuthenticationLabel(language, way)
		}).Label(authLabel).Grow(1).MinWidth(0).Disabled(disabled)
	})
	if f.authentication == core.RemoteAuthenticationPrivateKey {
		label := i18n.Shared(language, "desktop.remote.identityFile")
		a.remoteRow(c.Part("identityFile"), "identityFile", label, i18n.Shared(language, "desktop.remote.identityFileHelp"), func(k ui.C) {
			box := ui.TextField(k, &f.identityFile, label, i18n.Shared(language, "desktop.remote.identityFilePlaceholder")).Grow(1).MinWidth(0).Disabled(disabled).
				Action(icons.FolderOpen, i18n.Shared(language, "desktop.remote.choose"))
			if box.ActionClicked() {
				c.After(a.chooseRemoteIdentity)
			}
		})
	}
	ui.Collapsible(c.Part("advanced"), &f.advanced, i18n.Shared(language, "desktop.remote.advanced"), func() {
		k := c.Part("advanced-fields")
		ui.Column(k).FillWidth().Gap(10).Children(func() {
			text := func(key, label, placeholder, help string, field *ui.Field) {
				a.remoteRow(k.Part(key), key, label, help, func(k ui.C) {
					ui.TextField(k, field, label, placeholder).Grow(1).MinWidth(0).Disabled(disabled)
				})
			}
			text("proxyJump", i18n.Shared(language, "desktop.remote.proxyJump"), i18n.Shared(language, "desktop.remote.proxyJumpPlaceholder"), i18n.Shared(language, "desktop.remote.proxyJumpHelp"), &f.proxyJump)
			text("connectTimeoutSeconds", i18n.Shared(language, "desktop.remote.timeout"), i18n.Shared(language, "desktop.remote.timeoutPlaceholder"), "", &f.timeout)
			text("keepAliveSeconds", i18n.Shared(language, "desktop.remote.keepAlive"), i18n.Shared(language, "desktop.remote.keepAlivePlaceholder"), i18n.Shared(language, "desktop.remote.keepAliveHelp"), &f.keepAlive)
		})
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

// remoteRow declares one field: its label and ⓘ in the label column, the control beside them,
// and the reason Core refused field under the control.
func (a *App) remoteRow(c ui.C, field, label, help string, control func(ui.C)) {
	r := &a.remote
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().Gap(12).Items(ui.Center).Children(func() {
			ui.Row(c.Part("label")).Width(remoteLabelWidth).MinHeight(28).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
				ui.Text(c, label).Ellipsis().Shrink(1).MinWidth(0)
				if help != "" {
					a.remoteHelp(c, help)
				}
			})
			control(c)
		})
		if r.fieldErr.field == field {
			ui.Row(c.Part("error")).FillWidth().PadSides(0, 0, 0, remoteLabelWidth+12).Children(func() {
				ui.Paragraph(c, remoteRefusalText(a.language(), r.fieldErr), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			})
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

// remoteResult declares what the running or last test found: the host's platform and what it has
// for a connection, or why it failed with OpenSSH's own output under it. That output is upstream
// text, shown as Core passed it and never logged.
func (a *App) remoteResult(c ui.C, language i18n.Language) {
	r := &a.remote
	if r.probe != nil {
		a.remoteNotice(c, icons.LoaderCircle, a.colors.Subtle, i18n.Shared(language, "desktop.remote.testing"))
		return
	}
	outcome := r.result
	if outcome == nil {
		return
	}
	ui.Column(c).FillWidth().Gap(8).PadTop(6).Children(func() {
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		if outcome.err != nil {
			text := i18n.SharedFormat(language, "desktop.remote.probe.error", map[string]string{"reason": outcome.err.Error()})
			var coreErr *core.Error
			if errors.As(outcome.err, &coreErr) && coreErr.Code == core.CodeRuntimeMissing {
				text = i18n.Shared(language, "desktop.remote.probe.noSSH")
			}
			a.remoteNotice(c.Part("status"), icons.CircleX, a.theme.Danger, text)
			return
		}
		result := outcome.result
		host := result.Host
		var system, machine string
		if host != nil {
			system, machine = host.System, host.Machine
		}
		switch result.Status {
		case core.RemoteProbeConnected:
			a.remoteNotice(c.Part("status"), icons.CircleCheck, a.colors.Success,
				i18n.SharedFormat(language, "desktop.remote.probe.connected", map[string]string{"system": system, "machine": machine}))
		case core.RemoteProbeUnsupportedPlatform:
			a.remoteNotice(c.Part("status"), icons.CircleAlert, a.colors.Warning,
				i18n.SharedFormat(language, "desktop.remote.probe.unsupported", map[string]string{"system": system, "machine": machine}))
		case core.RemoteProbeAuthenticationFailed:
			a.remoteNotice(c.Part("status"), icons.CircleX, a.theme.Danger, i18n.Shared(language, "desktop.remote.probe.authenticationFailed"))
		case core.RemoteProbeHostKeyRejected:
			a.remoteNotice(c.Part("status"), icons.CircleX, a.theme.Danger, i18n.Shared(language, "desktop.remote.probe.hostKeyRejected"))
		case core.RemoteProbeUnreachable:
			a.remoteNotice(c.Part("status"), icons.CircleX, a.theme.Danger, i18n.Shared(language, "desktop.remote.probe.unreachable"))
		default:
			a.remoteNotice(c.Part("status"), icons.CircleX, a.theme.Danger, i18n.Shared(language, "desktop.remote.probe.failed"))
		}
		if host != nil {
			a.remoteHostDetails(c.Part("details"), language, *host)
		}
		if diagnostics := strings.TrimSpace(result.Diagnostics); diagnostics != "" && result.Status != core.RemoteProbeConnected {
			ui.Text(c, i18n.Shared(language, "desktop.remote.diagnostics")).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
			ui.Paragraph(c.Part("diagnostics"), diagnostics, 8).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
}

// remoteHostDetails declares what the host reported about itself, each item that it reported.
func (a *App) remoteHostDetails(c ui.C, language i18n.Language, host core.RemoteProbedHost) {
	details := host.Details
	type item struct{ label, value string }
	var items []item
	if details.HostName != "" {
		items = append(items, item{i18n.Shared(language, "desktop.remote.probe.hostName"), details.HostName})
	}
	if system := strings.TrimSpace(details.OperatingSystem + " " + details.Kernel); system != "" {
		items = append(items, item{i18n.Shared(language, "desktop.remote.probe.os"), system})
	}
	if details.CPUCount > 0 {
		items = append(items, item{i18n.Shared(language, "desktop.remote.probe.cpu"), strconv.FormatUint(uint64(details.CPUCount), 10)})
	}
	if details.MemoryBytes > 0 {
		items = append(items, item{i18n.Shared(language, "desktop.remote.probe.memory"), memorySize(language, details.MemoryBytes)})
	}
	if details.DiskTotalBytes > 0 {
		items = append(items, item{i18n.Shared(language, "desktop.remote.probe.disk"), i18n.SharedFormat(language, "desktop.remote.probe.diskSpace", map[string]string{
			"available": memorySize(language, details.DiskAvailableBytes),
			"total":     memorySize(language, details.DiskTotalBytes),
		})})
	}
	if len(items) == 0 {
		return
	}
	ui.Column(c).FillWidth().Gap(4).PadSides(0, 0, 0, 24).Children(func() {
		for index, entry := range items {
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().Gap(12).Items(ui.Center).Children(func() {
				ui.Text(k, entry.label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Width(remoteLabelWidth - 24).Shrink(0).Ellipsis()
				ui.Text(k, entry.value).FontSize(a.theme.Metrics.FontSizeS).Ellipsis().Grow(1).MinWidth(0)
			})
		}
	})
}

// remoteFooter declares Delete, or the question whether to delete, then Test Connection, Close and
// Save.
func (a *App) remoteFooter(c ui.C) {
	r := &a.remote
	language := a.language()
	entry := r.entry(r.selected)
	if r.confirmDelete && entry != nil {
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.deleteConfirm", map[string]string{"name": entry.Name})).Ellipsis().Shrink(1).MinWidth(0)
		if ui.Button(c.Part("delete-confirm"), i18n.Shared(language, "desktop.remote.delete")).Destructive().Disabled(!r.editable()).Clicked() {
			c.After(a.removeRemote)
		}
		if ui.Button(c.Part("delete-cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Clicked() {
			c.After(func() { r.confirmDelete = false })
		}
		ui.Spacer(c)
		return
	}
	if entry != nil {
		if ui.Button(c.Part("delete"), i18n.Shared(language, "desktop.remote.delete")).DestructiveOutline().Disabled(!r.editable()).Clicked() {
			c.After(func() { r.confirmDelete = true })
		}
	}
	ui.Spacer(c)
	if r.probe != nil {
		if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Outline().Clicked() {
			c.After(a.stopRemoteTest)
		}
	} else if ui.Button(c.Part("test"), i18n.Shared(language, "desktop.remote.test")).Outline().
		Disabled(strings.TrimSpace(r.form.host.Text()) == "").Clicked() {
		c.After(a.testRemote)
	}
	if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
		c.After(a.closeRemote)
	}
	label := i18n.Shared(language, "desktop.remote.save")
	if r.saving {
		label = i18n.Shared(language, "desktop.remote.saving")
	}
	if ui.Button(c.Part("save"), label).Disabled(!r.editable() || !r.dirty()).Clicked() {
		c.After(a.saveRemote)
	}
}
