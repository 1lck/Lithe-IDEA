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

// remoteList declares the saved connections under their groups, below a header with the button
// that starts a new one.
func (a *App) remoteList(c ui.C) {
	r := &a.remote
	language := a.language()
	k := c.Part("list")
	title := i18n.Shared(language, "desktop.remote.saved")
	ui.Column(k).Width(remoteListWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(k.Part("header")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(4).PadSides(0, 6, 0, 12).Children(func() {
			ui.Text(k, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			if path := r.source.Path(); path != "" {
				a.remoteHelp(k.Part("storage"), i18n.SharedFormat(language, "desktop.remote.storageHelp", map[string]string{"path": path}))
			}
			ui.Spacer(k)
			if a.gitIconButton(k.Part("new"), i18n.Shared(language, "desktop.remote.new"), icons.Plus, false, r.saving) {
				c.After(a.newRemote)
			}
		})
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		rows := r.rows
		if len(rows) == 0 {
			text := i18n.Shared(language, "desktop.remote.empty")
			if r.loading {
				text = i18n.Shared(language, "native.loading")
			}
			ui.Row(k.Part("empty")).FillWidth().Pad(12).Children(func() {
				ui.Paragraph(k, text, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			})
			return
		}
		r.list.Label = func(row int) string {
			if row < 0 || row >= len(r.rows) {
				return ""
			}
			if r.rows[row].heading {
				return remoteGroupHeading(language, r.rows[row].group)
			}
			return r.rows[row].entry.Name
		}
		r.list.Header = func(row int) bool { return row >= 0 && row < len(r.rows) && r.rows[row].heading }
		ui.List(k.Part("rows"), &r.list, len(rows), func(row ui.ListRow) {
			if item := rows[row.Index]; item.heading {
				a.remoteHeadingRow(row, language, item)
			} else {
				a.remoteEntryRow(row, *item.entry)
			}
		}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
		if r.list.Changed() {
			if at := r.list.Selected(); at >= 0 && at < len(rows) && rows[at].entry != nil && rows[at].entry.ID != r.selected {
				id := rows[at].entry.ID
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

// remoteGroupHeading is the heading of group in the list, "" being the connections without one.
func remoteGroupHeading(language i18n.Language, group string) string {
	if group == "" {
		return i18n.Shared(language, "desktop.remote.ungrouped")
	}
	return group
}

// remoteHeadingRow declares a group's heading with the number of its connections. It stays at the
// top while its connections scroll under it, so it has the window's background.
func (a *App) remoteHeadingRow(row ui.ListRow, language i18n.Language, heading remoteListRow) {
	rc := row.C
	row.Element.Height(remoteHeadingHeight).PadSides(0, 12, 0, 12).Gap(6).Items(ui.Center).Background(a.theme.Popover).Children(func() {
		ui.Text(rc, remoteGroupHeading(language, heading.group)).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).
			Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		ui.Text(rc, strconv.Itoa(heading.count)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

// remoteEntryRow declares a saved connection's row: its color's bar, its name and its address.
func (a *App) remoteEntryRow(row ui.ListRow, entry core.SavedRemoteConnection) {
	r := &a.remote
	rc := row.C
	row.Element.Height(remoteRowHeight).PadSides(0, 10, 0, 4).Gap(8).Items(ui.Center).Hover(ui.Look{}.Background(a.colors.Hover))
	// The row of the edited connection is highlighted, also in the frame a save added it,
	// before the list's own selection can reach it.
	if entry.ID == r.selected {
		row.Element.Background(a.colors.Selection)
	}
	row.Element.Children(func() {
		bar := ui.Row(rc).Width(3).Height(remoteRowHeight - 16).Shrink(0).Radius(1.5)
		if color, ok := remoteColor(a.colors.Dark, entry.Color); ok {
			bar.Background(color)
		}
		ui.Icon(rc, icons.Server).Size(16, 16).Shrink(0).Color(a.colors.Subtle)
		ui.Column(rc).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
			ui.Text(rc, entry.Name).Weight(gfx.WeightSemibold).Ellipsis()
			ui.Text(rc, remoteAddress(entry.Connection)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		})
	})
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

// remoteDetail declares the selected connection's overview, or the form with what the last test
// found under it.
func (a *App) remoteDetail(c ui.C) {
	r := &a.remote
	language := a.language()
	k := c.Part("detail")
	ui.Scroll(k).Scrollbars().Grow(1).FillHeight().MinWidth(0).Children(func() {
		ui.Column(k.Part("content")).FillWidth().PadSides(18, 22, 18, 22).Gap(14).Children(func() {
			if r.readErr != "" {
				a.remoteNotice(k.Part("read"), icons.CircleAlert, a.theme.Danger, r.readErr)
			}
			if entry := r.entry(r.selected); entry != nil && !r.editingForm() {
				a.remoteOverview(k.Part("overview"), language, *entry)
			} else {
				a.remoteFields(k.Part("form"))
			}
			if r.err != "" {
				ui.Paragraph(k.Part("error"), r.err, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			if r.editingForm() {
				a.remoteFormResult(k.Part("result"), language)
			}
		})
	})
}

// remoteOverview declares a saved connection: its mark, name, group and address with Edit, what
// the last test found about the host, and its settings.
func (a *App) remoteOverview(c ui.C, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	connection := entry.Connection
	ui.Row(c.Part("header")).FillWidth().Gap(12).Items(ui.Center).Children(func() {
		mark := ui.Row(c.Part("mark")).Size(40, 40).Shrink(0).Radius(8).Center()
		markIcon := a.colors.Subtle
		if color, ok := remoteColor(a.colors.Dark, entry.Color); ok {
			mark.Background(color)
			markIcon = gfx.RGB24(0xFFFFFF)
		} else {
			mark.Background(a.colors.Hover)
		}
		mark.Children(func() {
			ui.Icon(c, icons.Server).Size(20, 20).Color(markIcon)
		})
		ui.Column(c.Part("title")).Grow(1).Shrink(1).MinWidth(0).Gap(4).Children(func() {
			ui.Row(c.Part("name")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Text(c, entry.Name).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
				if entry.Group != "" {
					ui.Badge(c, entry.Group).Shrink(0)
				}
			})
			ui.Row(c.Part("address")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Text(c, remoteAddress(connection)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				if jump := strings.TrimSpace(connection.ProxyJump); jump != "" {
					ui.Text(c, i18n.SharedFormat(language, "desktop.remote.via", map[string]string{"jump": jump})).FontSize(a.theme.Metrics.FontSizeS).
						Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				}
			})
		})
		if ui.Button(c.Part("edit"), i18n.Shared(language, "desktop.remote.edit")).Icon(icons.Pencil).Outline().Disabled(r.saving).Clicked() {
			c.After(a.editSelectedRemote)
		}
	})
	ui.Row(c.Part("header-line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)

	a.remoteSectionHeading(c.Part("host-heading"), i18n.Shared(language, "desktop.remote.hostSection"))
	outcome := r.result
	if outcome == nil {
		outcome = r.probedOutcome(connection)
	}
	switch {
	case r.probe != nil:
		a.remoteNotice(c.Part("testing"), icons.LoaderCircle, a.colors.Subtle, i18n.Shared(language, "desktop.remote.testing"))
	case outcome == nil:
		ui.Paragraph(c.Part("untested"), i18n.Shared(language, "desktop.remote.untested"), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	default:
		a.remoteOutcome(c.Part("outcome"), language, outcome)
	}

	a.remoteSectionHeading(c.Part("settings-heading"), i18n.Shared(language, "desktop.remote.settings"))
	a.remoteSettings(c.Part("settings"), language, connection)
}

// remoteSectionHeading declares the heading of a part of the overview.
func (a *App) remoteSectionHeading(c ui.C, title string) {
	ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).PadTop(4)
}

// remoteSettings declares a saved connection's settings, one a line. A setting left to OpenSSH
// says what it falls back to, as the form's placeholder does.
func (a *App) remoteSettings(c ui.C, language i18n.Language, connection core.SSHConnection) {
	type setting struct {
		label, value string
		// fallback says the value is what an unset setting falls back to.
		fallback bool
	}
	set := func(label, value string) setting { return setting{label: label, value: value} }
	// optional is a setting that falls back to unset when value is "".
	optional := func(label, value, unset string) setting {
		if value == "" {
			return setting{label: label, value: unset, fallback: true}
		}
		return set(label, value)
	}
	settings := []setting{
		set(i18n.Shared(language, "desktop.remote.host"), connection.Host),
		optional(i18n.Shared(language, "desktop.remote.port"), optionalNumber(uint64(connection.Port)), i18n.Shared(language, "desktop.remote.portPlaceholder")),
		optional(i18n.Shared(language, "desktop.remote.user"), connection.User, i18n.Shared(language, "desktop.remote.userPlaceholder")),
		set(i18n.Shared(language, "desktop.remote.authentication"), remoteAuthenticationLabel(language, connection.Authentication)),
	}
	if connection.Authentication == core.RemoteAuthenticationPrivateKey {
		settings = append(settings, set(i18n.Shared(language, "desktop.remote.identityFile"), connection.IdentityFile))
	}
	settings = append(settings,
		optional(i18n.Shared(language, "desktop.remote.proxyJump"), connection.ProxyJump, i18n.Shared(language, "desktop.remote.proxyJumpPlaceholder")),
		optional(i18n.Shared(language, "desktop.remote.timeout"), optionalNumber(uint64(connection.ConnectTimeoutSeconds)),
			i18n.Shared(language, "desktop.remote.timeoutPlaceholder")),
		optional(i18n.Shared(language, "desktop.remote.keepAlive"), optionalNumber(uint64(connection.KeepAliveSeconds)),
			i18n.Shared(language, "desktop.remote.keepAlivePlaceholder")),
	)
	ui.Column(c).FillWidth().Border(1, a.colors.Line).Radius(6).Children(func() {
		for index, entry := range settings {
			k := c.KeyInt(index)
			if index > 0 {
				ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			}
			ui.Row(k).FillWidth().MinHeight(32).PadX(12).Gap(12).Items(ui.Center).Children(func() {
				ui.Text(k, entry.label).Color(a.colors.Subtle).Width(remoteSettingWidth).Shrink(0).Ellipsis()
				value := ui.Text(k, entry.value).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
				if entry.fallback {
					value.Color(a.colors.Subtle)
				}
			})
		}
	})
}

// remoteFields declares the form: two or three fields a line, each under its label, with the
// advanced options folded below.
func (a *App) remoteFields(c ui.C) {
	r := &a.remote
	f := &r.form
	language := a.language()
	disabled := r.saving
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
				text(k, label, i18n.Shared(language, "desktop.remote.portPlaceholder"), &f.port)
			})
		})
		line("line-user", func(k ui.C) {
			label := i18n.Shared(language, "desktop.remote.user")
			a.remoteCell(k.Part("user"), "user", label, "", 0, func(k ui.C) {
				text(k, label, i18n.Shared(language, "desktop.remote.userPlaceholder"), &f.user)
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
		ui.Collapsible(c.Part("advanced"), &f.advanced, i18n.Shared(language, "desktop.remote.advanced"), func() {
			k := c.Part("advanced-fields")
			ui.Column(k).FillWidth().Gap(14).PadTop(4).Children(func() {
				label := i18n.Shared(language, "desktop.remote.proxyJump")
				a.remoteCell(k.Part("proxyJump"), "proxyJump", label, i18n.Shared(language, "desktop.remote.proxyJumpHelp"), 0, func(k ui.C) {
					text(k, label, i18n.Shared(language, "desktop.remote.proxyJumpPlaceholder"), &f.proxyJump)
				})
				ui.Row(k.Part("line-timing")).FillWidth().Gap(14).Items(ui.Start).Children(func() {
					label := i18n.Shared(language, "desktop.remote.timeout")
					a.remoteCell(k.Part("connectTimeoutSeconds"), "connectTimeoutSeconds", label, "", 0, func(k ui.C) {
						text(k, label, i18n.Shared(language, "desktop.remote.timeoutPlaceholder"), &f.timeout)
					})
					label = i18n.Shared(language, "desktop.remote.keepAlive")
					a.remoteCell(k.Part("keepAliveSeconds"), "keepAliveSeconds", label, i18n.Shared(language, "desktop.remote.keepAliveHelp"), 0, func(k ui.C) {
						text(k, label, i18n.Shared(language, "desktop.remote.keepAlivePlaceholder"), &f.keepAlive)
					})
				})
			})
		})
	})
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
			ui.Paragraph(c.Part("error"), remoteRefusalText(a.language(), r.fieldErr), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
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

// remoteFormResult declares, under the form, what the running or last test of what it holds
// found.
func (a *App) remoteFormResult(c ui.C, language i18n.Language) {
	r := &a.remote
	if r.probe == nil && r.result == nil {
		return
	}
	ui.Column(c).FillWidth().Gap(10).PadTop(2).Children(func() {
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		if r.probe != nil {
			a.remoteNotice(c.Part("testing"), icons.LoaderCircle, a.colors.Subtle, i18n.Shared(language, "desktop.remote.testing"))
			return
		}
		a.remoteOutcome(c.Part("outcome"), language, r.result)
	})
}

// remoteOutcome declares what a test found: the host's platform and what it has for a connection,
// or why it failed with OpenSSH's own output under it. That output is upstream text, shown as Core
// passed it and never logged.
func (a *App) remoteOutcome(c ui.C, language i18n.Language, outcome *remoteProbeOutcome) {
	ui.Column(c).FillWidth().Gap(8).Children(func() {
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
				ui.Text(k, entry.label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Width(remoteSettingWidth - 24).Shrink(0).Ellipsis()
				ui.Text(k, entry.value).FontSize(a.theme.Metrics.FontSizeS).Ellipsis().Grow(1).MinWidth(0)
			})
		}
	})
}

// remoteFooter declares the footer. The overview has Delete, or the question whether to delete,
// then Test Connection and Close; the form has Test Connection, then Cancel (Close while nothing
// is saved to go back to) and Save.
func (a *App) remoteFooter(c ui.C) {
	r := &a.remote
	language := a.language()
	entry := r.entry(r.selected)
	if !r.editingForm() {
		if r.confirmDelete {
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
		if ui.Button(c.Part("delete"), i18n.Shared(language, "desktop.remote.delete")).DestructiveOutline().Disabled(!r.editable()).Clicked() {
			c.After(func() { r.confirmDelete = true })
		}
		ui.Spacer(c)
		a.remoteTestButton(c, language)
		if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
			c.After(a.closeRemote)
		}
		return
	}
	a.remoteTestButton(c, language)
	ui.Spacer(c)
	if entry != nil || len(r.rows) > 0 {
		if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Disabled(r.saving).Clicked() {
			c.After(a.cancelRemoteEdit)
		}
	} else if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
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

// remoteTestButton declares Test Connection, or Stop while a test runs.
func (a *App) remoteTestButton(c ui.C, language i18n.Language) {
	r := &a.remote
	if r.probe != nil {
		if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Outline().Clicked() {
			c.After(a.stopRemoteTest)
		}
		return
	}
	if ui.Button(c.Part("test"), i18n.Shared(language, "desktop.remote.test")).Outline().
		Disabled(strings.TrimSpace(r.form.host.Text()) == "").Clicked() {
		c.After(a.testRemote)
	}
}
