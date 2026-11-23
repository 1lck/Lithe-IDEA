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

// This file draws the page beside the Remote Development window's list: the first page when no
// connection is saved, a saved connection's overview, and the form that edits one, with the
// footer each of them has.

// remoteHeroTile is the size of the mark above a connection's overview.
const remoteHeroTile = 44

// remoteFolderRowHeight is the height of a folder in a list of folders.
const remoteRecentRowHeight = 32

// remotePage declares the page for what the list selected.
func (a *App) remotePage(c ui.C, language i18n.Language) {
	r := &a.remote
	if r.steps != nil {
		a.remoteStepsView(c, language, r.steps)
		return
	}
	entry := r.entry(r.selected)
	switch {
	case r.wsl.selected != "":
		a.remoteWSLPage(c, language)
	case r.containers.selected != nil:
		a.remoteContainerPage(c, language)
	case r.editing:
		a.remoteFormPage(c, language)
	case entry != nil:
		a.remoteOverview(c, language, *entry)
	case r.loading && !r.loaded:
		ui.Column(c).Fill().Center().Children(func() {
			ui.Spinner(c)
		})
	default:
		a.remoteEmptyPage(c, language)
	}
}

// remoteNotices declares why the connections could not be read or the last change failed.
func (a *App) remoteNotices(c ui.C) {
	r := &a.remote
	if r.readErr != "" {
		a.remoteNotice(c.Part("read-error"), icons.CircleX, a.theme.Danger, r.readErr)
	}
	if r.err != "" {
		a.remoteNotice(c.Part("error"), icons.CircleX, a.theme.Danger, r.err)
	}
}

// remoteSection declares a titled part of a page, with what it offers on the right of its title.
func (a *App) remoteSection(c ui.C, title, help string, actions func(), body func()) {
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		ui.Row(c.Part("head")).FillWidth().Height(22).Items(ui.Center).Gap(4).Children(func() {
			ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Shrink(0)
			if help != "" {
				a.remoteHelp(c.Part("section-help"), help)
			}
			ui.Spacer(c)
			if actions != nil {
				actions()
			}
		})
		body()
	})
}

// remoteBordered declares the bordered box the overview's lists and tables sit in.
func (a *App) remoteBordered(c ui.C) ui.Box {
	return ui.Column(c).FillWidth().Radius(6).Stroke(1, a.colors.Line).Clip()
}

// remoteEmptyPage is the first page while no connection is saved: an address to start from, the
// hosts other tools already know, and the form for the rest.
func (a *App) remoteEmptyPage(c ui.C, language i18n.Language) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	ui.Scroll(c.Part("empty")).Fill().Children(func() {
		ui.Column(c).FillWidth().Items(ui.Center).PadSides(56, 32, 32, 32).Children(func() {
			ui.Column(c.Part("card")).Width(420).Gap(16).Children(func() {
				a.remoteNotices(c)
				ui.Row(c).Size(40, 40).Center().Radius(10).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
					ui.Icon(c, icons.Server).Size(20, 20).Color(a.colors.Subtle)
				})
				ui.Column(c).FillWidth().Gap(6).Children(func() {
					ui.Text(c, i18n.Shared(language, "desktop.remote.empty.title")).FontSize(16).Weight(gfx.WeightSemibold)
					ui.Paragraph(c, i18n.Shared(language, "desktop.remote.empty.body"), 3).Color(a.colors.Subtle)
				})
				ui.Column(c).FillWidth().Gap(6).Children(func() {
					ui.Text(c, i18n.Shared(language, "desktop.remote.quick.label")).FontSize(small).Weight(gfx.WeightMedium)
					ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
						field := ui.TextField(c.Part("quick"), &r.quick, i18n.Shared(language, "desktop.remote.quick.label"), i18n.Shared(language, "desktop.remote.quick.placeholder")).
							Mono().Grow(1).Basis(0).MinWidth(0).Disabled(!r.editable())
						if field.Submitted() {
							c.After(a.quickRemote)
						}
						if ui.Button(c.Part("quick-go"), i18n.Shared(language, "desktop.remote.quick.continue")).Disabled(!r.editable() || strings.TrimSpace(r.quick.Text()) == "").Clicked() {
							c.After(a.quickRemote)
						}
					})
					if r.quickErr != "" {
						ui.Text(c, r.quickErr).FontSize(small).Color(a.theme.Danger)
					}
				})
				ui.Row(c).FillWidth().Gap(10).Children(func() {
					a.remoteImportCard(c.Part("motty"), language, remoteImportMotty, "M", i18n.Shared(language, "desktop.remote.empty.importMotty"), r.imports.motty)
					a.remoteImportCard(c.Part("ssh"), language, remoteImportSSH, "~", i18n.Shared(language, "desktop.remote.empty.importSsh"), r.imports.sshConfig)
				})
				if ui.Button(c.Part("manual"), i18n.Shared(language, "desktop.remote.empty.manual")).Link().Disabled(!r.editable()).Clicked() {
					c.After(a.newRemote)
				}
				if ui.Button(c.Part("devcontainer"), i18n.Shared(language, "desktop.remote.devcontainer.open")).Link().Disabled(r.saving || r.connect != nil).Clicked() {
					c.After(a.openRemoteDevcontainer)
				}
			})
		})
	})
}

// remoteImportCard declares a source to import hosts from, with how many it holds.
func (a *App) remoteImportCard(c ui.C, language i18n.Language, source remoteImportSource, mark, title string, count int) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	disabled := !r.editable()
	card := ui.Row(c).Grow(1).Basis(0).MinWidth(0).Items(ui.Center).Gap(10).Pad(12).Radius(6).Stroke(1, a.colors.Line).
		HitWith(ui.ID(c), title, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Disabled: disabled}).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	card.Children(func() {
		ui.Row(c).Size(28, 28).Shrink(0).Center().Radius(6).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
			ui.Text(c, mark).Mono().Weight(gfx.WeightBold).Color(a.colors.Subtle)
		})
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
			ui.Text(c, title).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
			count := a.remoteImportCountText(language, count)
			if !r.imports.loaded {
				count = i18n.Shared(language, "native.loading")
			}
			ui.Text(c, count).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
		})
	})
	if !disabled && card.Clicked() {
		c.After(func() { a.openRemoteImport(source) })
	}
}

// remoteOverview declares a saved connection's page: who it is, the folders opened on it, the
// host it reached and what OpenSSH will use to reach it.
func (a *App) remoteOverview(c ui.C, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	outcome := r.probedOutcome(entry.Connection)
	ui.Scroll(c.Part("overview")).Fill().Children(func() {
		ui.Column(c).FillWidth().Gap(22).PadSides(20, 24, 24, 24).Children(func() {
			a.remoteNotices(c)
			a.remoteHero(c.Part("hero"), language, entry, outcome)
			a.remoteRecentSection(c.Part("recent"), language, entry)
			a.remoteHostSection(c.Part("host"), language, outcome)
			a.remoteEffectiveSection(c.Part("effective"), language, entry)
		})
	})
}

// remoteHero declares the overview's head: the host's mark, the connection's name, group and
// address, and what can be done with it.
func (a *App) remoteHero(c ui.C, language i18n.Language, entry core.SavedRemoteConnection, outcome *remoteProbeOutcome) {
	r := &a.remote
	ui.Row(c).FillWidth().Items(ui.Center).Gap(14).Children(func() {
		a.remoteTile(c.Part("tile"), remoteSystemMark(outcome), entry.Name, entry.Color, remoteHeroTile, 15)
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				if tint, ok := remoteColor(a.colors.Dark, entry.Color); ok {
					a.remoteDot(c.Part("color"), tint, 8)
				}
				ui.Text(c, entry.Name).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
				if entry.Group != "" {
					a.remotePill(c.Part("group"), entry.Group, a.colors.Subtle)
				}
				if windows := a.remoteWindows(entry.ID); windows > 0 {
					a.remoteStatusPill(c.Part("live"), i18n.SharedFormat(language, "desktop.remote.connectedWindows", map[string]string{"count": strconv.Itoa(windows)}), a.colors.Success)
				}
			})
			ui.Row(c.Part("address")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Text(c, remoteAddress(entry.Connection)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(0).MinWidth(0)
				if hops := remoteHopList(entry.Connection.ProxyJump); len(hops) > 0 {
					ui.Text(c, "·  "+i18n.SharedFormat(language, "desktop.remote.viaHosts", map[string]string{"hosts": strings.Join(hops, " › ")})).
						FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				}
			})
		})
		if ui.Button(c.Part("edit"), i18n.Shared(language, "desktop.remote.edit")).Icon(icons.Pencil).Outline().Shrink(0).Disabled(!r.editable()).Clicked() {
			c.After(a.editSelectedRemote)
		}
		a.remoteMoreMenu(c.Part("more"), language, entry)
		if ui.Button(c.Part("open"), i18n.Shared(language, "desktop.remote.openFolder")).Icon(icons.FolderOpen).Shrink(0).Disabled(!r.connectable()).Clicked() {
			c.After(func() { a.connectRemote("") })
		}
	})
}

// remoteMoreMenu declares the overview's ⋯ button and what it opens.
func (a *App) remoteMoreMenu(c ui.C, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	anchor, clicked := a.gitToolButton(c, i18n.Shared(language, "desktop.remote.more"), icons.Ellipsis, r.moreMenu, false)
	if clicked {
		c.After(func() { r.moreMenu = !r.moreMenu })
	}
	if !r.moreMenu {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		if menu.Item(i18n.Shared(language, "desktop.remote.test")).Disabled(r.probe != nil).Clicked() {
			c.After(a.testRemote)
		}
		if menu.Item(i18n.Shared(language, "desktop.remote.copyAsNew")).Icon(icons.Copy).Disabled(!r.editable()).Clicked() {
			c.After(a.copyRemoteAsNew)
		}
		if menu.Item(i18n.Shared(language, "desktop.remote.forgetAnswers")).Icon(icons.Eraser).Clicked() {
			c.After(func() { a.forgetRemoteAnswers(entry) })
		}
		menu.Separator()
		remove := menu.Item(i18n.SharedFormat(language, "desktop.remote.deleteNamed", map[string]string{"name": entry.Name})).
			Icon(icons.Trash2).Destructive().Disabled(!r.editable())
		if remove.Clicked() {
			c.After(func() {
				a.performed("remote.connection.deleteAsk", surfaceMenu)
				r.confirmDelete = true
			})
		}
	})
	if !open {
		r.moreMenu = false
	}
}

// remoteRecentSection declares the folders last opened on the connection; choosing one connects
// and opens it.
func (a *App) remoteRecentSection(c ui.C, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	a.remoteSection(c, i18n.Shared(language, "desktop.remote.recentFolders"), "", func() {
		if ui.Button(c.Part("other"), i18n.Shared(language, "desktop.remote.openOther")).Link().Disabled(!r.connectable()).Clicked() {
			c.After(func() { a.connectRemote("") })
		}
	}, func() {
		if len(entry.RecentFolders) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.remote.noRecentFolders")).FontSize(small).Color(a.colors.Subtle)
			return
		}
		a.remoteBordered(c.Part("folders")).Children(func() {
			for index, folder := range entry.RecentFolders {
				k := c.KeyInt(index)
				if index > 0 {
					ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
				}
				disabled := !r.connectable()
				row := ui.Row(k).FillWidth().Height(remoteRecentRowHeight).Items(ui.Center).Gap(8).PadX(10).
					HitWith(ui.ID(k), folder, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Disabled: disabled}).
					Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
				row.Children(func() {
					ui.Icon(c, icons.Folder).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
					ui.Text(c, folder).Mono().FontSize(small).Ellipsis().Grow(1).MinWidth(0)
					ui.Icon(c, icons.ChevronRight).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
				})
				if !disabled && row.Clicked() {
					folder := folder
					k.After(func() { a.connectRemote(folder) })
				}
			}
		})
	})
}

// remoteHostSection declares what the last test found on the host, and the button that tests it
// again.
func (a *App) remoteHostSection(c ui.C, language i18n.Language, outcome *remoteProbeOutcome) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	a.remoteSection(c, i18n.Shared(language, "desktop.remote.hostSection"), "", func() {
		if r.probe != nil {
			ui.Spinner(c).Size(12, 12)
			ui.Text(c, i18n.Shared(language, "desktop.remote.testing")).FontSize(small).Color(a.colors.Subtle)
			if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Link().Clicked() {
				c.After(a.stopRemoteTest)
			}
			return
		}
		label := i18n.Shared(language, "desktop.remote.test")
		if outcome != nil {
			if !outcome.at.IsZero() {
				ui.Text(c, i18n.SharedFormat(language, "desktop.remote.testedAgo", map[string]string{"time": relativeGitTime(language, a.now(), outcome.at)})).
					FontSize(small).Color(a.colors.Subtle)
			}
			label = i18n.Shared(language, "desktop.remote.retest")
		}
		if ui.Button(c.Part("test"), label).Link().Clicked() {
			c.After(a.testRemote)
		}
	}, func() {
		switch {
		case outcome == nil:
			ui.Text(c, i18n.Shared(language, "desktop.remote.untested")).FontSize(small).Color(a.colors.Subtle)
		case outcome.err == nil && outcome.result.Status == core.RemoteProbeConnected && outcome.result.Host != nil:
			a.remoteHostGrid(c.Part("grid"), language, *outcome.result.Host)
		default:
			a.remoteOutcomeBox(c.Part("outcome"), language, outcome)
		}
	})
}

// remoteHostGrid declares the host's system, processor, memory and disk side by side.
func (a *App) remoteHostGrid(c ui.C, language i18n.Language, host core.RemoteProbedHost) {
	details := host.Details
	small := a.theme.Metrics.FontSizeS
	type cell struct{ label, value, detail string }
	system := strings.TrimSpace(details.OperatingSystem)
	if system == "" {
		system = host.System
	}
	// The host name is the machine that answered, which a load balancer or a jump host may pick.
	cells := []cell{
		{i18n.Shared(language, "desktop.remote.probe.hostName"), strings.TrimSpace(details.HostName), host.HomeDirectory},
		{i18n.Shared(language, "desktop.remote.probe.os"), system, details.Kernel},
		{i18n.Shared(language, "desktop.remote.probe.cpu"), host.Machine, ""},
		{i18n.Shared(language, "desktop.remote.probe.memory"), "", ""},
		{i18n.Shared(language, "desktop.remote.probe.disk"), "", ""},
	}
	if details.CPUCount > 0 {
		cells[2].detail = i18n.SharedFormat(language, "desktop.remote.host.cores", map[string]string{"count": strconv.FormatUint(uint64(details.CPUCount), 10)})
	}
	if details.MemoryBytes > 0 {
		cells[3].value = memorySize(language, details.MemoryBytes)
	}
	if details.DiskTotalBytes > 0 {
		cells[4].value = memorySize(language, details.DiskAvailableBytes)
		cells[4].detail = i18n.SharedFormat(language, "desktop.remote.host.diskOf", map[string]string{"total": memorySize(language, details.DiskTotalBytes)})
	}
	ui.Row(c).FillWidth().Radius(6).Stroke(1, a.colors.Line).Clip().Children(func() {
		for index, item := range cells {
			k := c.KeyInt(index)
			if index > 0 {
				ui.Column(k.Part("line")).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
			}
			value := item.value
			if value == "" {
				value = "—"
			}
			ui.Column(k).Grow(1).Basis(0).MinWidth(0).Gap(3).PadSides(10, 12, 10, 12).Children(func() {
				ui.Text(c, item.label).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
				ui.Text(c, value).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
				if item.detail != "" {
					ui.Text(c, item.detail).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
				}
			})
		}
	})
}

// remoteOutcomeBox declares how a test ended: green with the host in short tags when it
// connected, red with why it did not and what to check, and OpenSSH's own words under the box,
// which its link shows or hides.
func (a *App) remoteOutcomeBox(c ui.C, language i18n.Language, outcome *remoteProbeOutcome) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	connected := outcome.err == nil && outcome.result.Status == core.RemoteProbeConnected
	tint, icon := a.theme.Danger, icons.X
	if connected {
		tint, icon = a.colors.Success, icons.Check
	} else if outcome.err == nil && outcome.result.Status == core.RemoteProbeUnsupportedPlatform {
		tint, icon = a.colors.Warning, icons.CircleAlert
	}
	diagnostics := strings.TrimSpace(outcome.result.Diagnostics)
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		k := c.Part("box")
		ui.Column(k).FillWidth().Gap(6).PadSides(10, 14, 10, 12).Radius(6).Background(tint.WithAlpha(0.08)).Stroke(1, tint.WithAlpha(0.35)).Children(func() {
			ui.Row(k).FillWidth().Gap(8).Items(ui.Start).Children(func() {
				ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(tint).MarginTop(2)
				if connected {
					var system, machine string
					if host := outcome.result.Host; host != nil {
						system, machine = host.System, host.Machine
					}
					line := k.Part("line")
					ui.Row(line).Grow(1).MinWidth(0).Items(ui.Center).Children(func() {
						ui.Text(line, i18n.SharedFormat(language, "desktop.remote.probe.connected", map[string]string{"system": system, "machine": machine})).
							Weight(gfx.WeightSemibold).Color(tint).Shrink(0)
						ui.Text(line, i18n.Shared(language, "desktop.remote.probe.usable")).Color(tint).Ellipsis().MinWidth(0)
					})
				} else {
					ui.Paragraph(c, remoteFailureText(language, outcome), 4).Weight(gfx.WeightMedium).Color(tint).Grow(1).MinWidth(0)
				}
				if diagnostics != "" {
					label := i18n.Shared(language, "desktop.remote.diagnostics")
					if r.log.Open {
						label = i18n.Shared(language, "desktop.remote.probe.hideOutput")
					}
					if ui.Button(k.Part("output"), label).Link().Clicked() {
						c.After(func() { r.log.Open = !r.log.Open })
					}
				}
			})
			if connected && outcome.result.Host != nil {
				a.remoteHostTags(k, language, *outcome.result.Host)
			} else if hint := remoteFailureHint(language, outcome); hint != "" {
				ui.Paragraph(c, hint, 4).FontSize(small).Color(tint).MarginLeft(22)
			}
		})
		if diagnostics != "" && r.log.Open {
			l := c.Part("log")
			ui.Scroll(l).FillWidth().MaxHeight(180).Children(func() {
				ui.Column(l).FillWidth().PadSides(10, 12, 10, 12).Radius(6).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
					ui.Paragraph(c, diagnostics, 40).Mono().FontSize(small).Color(a.colors.Subtle)
				})
			})
		}
	})
}

// remoteHostTags declares what a test found on the host as short tags in one wrapped line:
// system, host name, cores, memory and the home folder's disk.
func (a *App) remoteHostTags(c ui.C, language i18n.Language, host core.RemoteProbedHost) {
	details := host.Details
	var tags []string
	if system := strings.TrimSpace(details.OperatingSystem); system != "" {
		tags = append(tags, system)
	}
	if name := strings.TrimSpace(details.HostName); name != "" {
		tags = append(tags, i18n.SharedFormat(language, "desktop.remote.probe.hostNameTag", map[string]string{"name": name}))
	}
	if details.CPUCount > 0 {
		tags = append(tags, i18n.SharedFormat(language, "desktop.remote.host.cores", map[string]string{"count": strconv.FormatUint(uint64(details.CPUCount), 10)}))
	}
	if details.MemoryBytes > 0 {
		tags = append(tags, i18n.SharedFormat(language, "desktop.remote.probe.memoryTag", map[string]string{"size": memorySize(language, details.MemoryBytes)}))
	}
	if details.DiskTotalBytes > 0 {
		tags = append(tags, i18n.SharedFormat(language, "desktop.remote.probe.diskSpace", map[string]string{
			"available": memorySize(language, details.DiskAvailableBytes), "total": memorySize(language, details.DiskTotalBytes)}))
	}
	if len(tags) == 0 {
		return
	}
	ui.Flow(c.Part("tags")).FillWidth().Gap(6).MarginLeft(22).Children(func() {
		for index, tag := range tags {
			a.remoteTag(c.KeyInt(index), tag, a.colors.Subtle)
		}
	})
}

// remoteFailureHint says what to check after a test that did not connect, and is "" when there
// is nothing more to say than why it failed.
func remoteFailureHint(language i18n.Language, outcome *remoteProbeOutcome) string {
	// The hints name OpenSSH's settings, which a WSL distribution and a container of this
	// computer do not have.
	if outcome.err != nil || outcome.wsl || outcome.engine != "" {
		return ""
	}
	switch outcome.result.Status {
	case core.RemoteProbeAuthenticationFailed:
		return i18n.SharedFormat(language, "desktop.remote.probe.hint.authentication", map[string]string{"method": i18n.Shared(language, "desktop.remote.auth.privateKey")})
	case core.RemoteProbeHostKeyRejected:
		return i18n.Shared(language, "desktop.remote.probe.hint.hostKey")
	case core.RemoteProbeUnreachable:
		return i18n.Shared(language, "desktop.remote.probe.hint.unreachable")
	}
	return ""
}

// remoteEffectiveSection declares what OpenSSH will use to reach the host, as `ssh -G` resolves
// it, and where each value comes from.
func (a *App) remoteEffectiveSection(c ui.C, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	small := a.theme.Metrics.FontSizeS
	state, asked := r.effective[entry.Connection]
	if !asked {
		connection := entry.Connection
		c.After(func() { a.loadRemoteEffective(connection) })
	}
	a.remoteSection(c, i18n.Shared(language, "desktop.remote.effective"), i18n.Shared(language, "desktop.remote.effectiveHelp"), func() {
		if ui.Button(c.Part("edit"), i18n.Shared(language, "desktop.remote.edit")).Link().Disabled(!r.editable()).Clicked() {
			c.After(a.editSelectedRemote)
		}
	}, func() {
		switch {
		case state == nil:
			ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(small).Color(a.colors.Subtle)
		case state.err != nil:
			a.remoteNotice(c.Part("failed"), icons.CircleX, a.theme.Danger,
				i18n.SharedFormat(language, "desktop.remote.effectiveFailed", map[string]string{"reason": remoteLogError(state.err).Error()}))
		default:
			a.remoteEffectiveTable(c.Part("table"), language, state.settings)
		}
	})
}

// remoteEffectiveTable declares the resolved values, one per row, with their source.
func (a *App) remoteEffectiveTable(c ui.C, language i18n.Language, settings core.RemoteEffectiveSettings) {
	type line struct {
		key, value string
		source     core.RemoteSettingSource
		words      bool
	}
	number := func(value core.RemoteEffectiveNumber, seconds bool) string {
		text := strconv.FormatUint(uint64(value.Value), 10)
		if seconds {
			text = i18n.SharedFormat(language, "desktop.remote.seconds", map[string]string{"count": text})
		}
		return text
	}
	lines := []line{
		{i18n.Shared(language, "desktop.remote.setting.hostName"), settings.HostName.Value, settings.HostName.Source, false},
		{i18n.Shared(language, "desktop.remote.setting.user"), settings.User.Value, settings.User.Source, false},
		{i18n.Shared(language, "desktop.remote.setting.port"), number(settings.Port, false), settings.Port.Source, false},
	}
	if len(settings.IdentityFiles.Value) > 0 {
		lines = append(lines, line{i18n.Shared(language, "desktop.remote.setting.identityFiles"), strings.Join(settings.IdentityFiles.Value, ", "), settings.IdentityFiles.Source, false})
	}
	if jump := settings.ProxyJump; jump != nil && jump.Value != "" {
		lines = append(lines, line{i18n.Shared(language, "desktop.remote.setting.proxyJump"), jump.Value, jump.Source, false})
	}
	lines = append(lines,
		line{i18n.Shared(language, "desktop.remote.setting.connectTimeout"), number(settings.ConnectTimeoutSeconds, true), settings.ConnectTimeoutSeconds.Source, true},
		line{i18n.Shared(language, "desktop.remote.setting.keepAlive"), number(settings.KeepAliveSeconds, true), settings.KeepAliveSeconds.Source, true},
	)
	small := a.theme.Metrics.FontSizeS
	a.remoteBordered(c).Children(func() {
		for index, item := range lines {
			if index > 0 {
				ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			}
			ui.Row(c.KeyInt(index)).FillWidth().Height(30).Items(ui.Center).Gap(10).PadX(12).Children(func() {
				ui.Text(c, item.key).FontSize(small).Color(a.colors.Subtle).Width(140).Shrink(0).Ellipsis()
				value := ui.Text(c, item.value).FontSize(small).Ellipsis().Grow(1).MinWidth(0)
				if !item.words {
					value.Mono()
				}
				a.remotePill(c.Part("source"), remoteSourceName(language, item.source), a.colors.Subtle)
			})
		}
	})
}

// remoteSourceName names where an effective value comes from.
func remoteSourceName(language i18n.Language, source core.RemoteSettingSource) string {
	switch source {
	case core.RemoteSettingFromConnection:
		return i18n.Shared(language, "desktop.remote.source.connection")
	case core.RemoteSettingFromSSHConfig:
		return i18n.Shared(language, "desktop.remote.source.sshConfig")
	}
	return i18n.Shared(language, "desktop.remote.source.default")
}

// remoteFormPage declares the form that edits a connection or makes a new one, and the outcome
// of its test. The window's title names the connection the form edits.
func (a *App) remoteFormPage(c ui.C, language i18n.Language) {
	r := &a.remote
	ui.Scroll(c.Part("form")).Fill().Children(func() {
		ui.Column(c).FillWidth().Gap(16).PadSides(18, 24, 24, 24).Children(func() {
			a.remoteNotices(c)
			a.remoteFields(c)
			// The test runs from the footer; its outcome goes under the fields, the advanced ones
			// included, as the last thing the form says about the connection.
			switch {
			case r.probe != nil:
				ui.Row(c.Part("testing")).FillWidth().Items(ui.Center).Gap(8).Pad(12).Radius(6).Stroke(1, a.colors.Line).Children(func() {
					ui.Spinner(c).Size(14, 14)
					ui.Text(c, i18n.Shared(language, "desktop.remote.testing")).Color(a.colors.Subtle)
				})
			case r.result != nil:
				a.remoteOutcomeBox(c.Part("outcome"), language, r.result)
			}
		})
	})
}

// remoteFooter declares the buttons under the list and its page.
func (a *App) remoteFooter(c ui.C, language i18n.Language) {
	r := &a.remote
	entry := r.entry(r.selected)
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		switch {
		case r.wsl.selected != "":
			a.remoteWSLFooter(c, language)
		case r.containers.selected != nil:
			a.remoteContainerFooter(c, language)
		case r.editing:
			a.remoteFormFooter(c, language, entry)
		case entry != nil && r.confirmDelete:
			ui.Text(c, i18n.SharedFormat(language, "desktop.remote.deleteConfirm", map[string]string{"name": entry.Name})).Ellipsis().Grow(1).MinWidth(0)
			if ui.Button(c.Part("cancel-delete"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Clicked() {
				c.After(func() { r.confirmDelete = false })
			}
			if ui.Button(c.Part("delete"), i18n.Shared(language, "desktop.remote.delete")).Destructive().Disabled(r.saving).Clicked() {
				c.After(a.removeRemote)
			}
		default:
			ui.Spacer(c)
			if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
				c.After(a.closeRemote)
			}
		}
	})
}

// remoteFormFooter declares the form's buttons: test it, and save it, or save and connect a saved
// one.
func (a *App) remoteFormFooter(c ui.C, language i18n.Language, entry *core.SavedRemoteConnection) {
	r := &a.remote
	if r.probe != nil {
		if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Outline().Clicked() {
			c.After(a.stopRemoteTest)
		}
	} else if ui.Button(c.Part("test"), i18n.Shared(language, "desktop.remote.test")).Outline().Disabled(r.saving || strings.TrimSpace(r.form.host.Text()) == "").Clicked() {
		c.After(a.testRemote)
	}
	dirty := r.dirty()
	if dirty && entry != nil {
		ui.Text(c, i18n.Shared(language, "desktop.remote.unsaved")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	}
	ui.Spacer(c)
	cancel := i18n.Shared(language, "desktop.remote.cancel")
	if entry == nil && len(r.source.Connections) == 0 {
		cancel = i18n.Shared(language, "desktop.remote.close")
	}
	if ui.Button(c.Part("cancel"), cancel).Outline().Disabled(r.saving).Clicked() {
		if entry == nil && len(r.source.Connections) == 0 {
			c.After(a.closeRemote)
		} else {
			c.After(a.cancelRemoteEdit)
		}
	}
	save := i18n.Shared(language, "desktop.remote.save")
	if r.saving {
		save = i18n.Shared(language, "desktop.remote.saving")
	}
	if entry == nil {
		if ui.Button(c.Part("save"), save).Disabled(!r.editable() || r.saving).Clicked() {
			c.After(a.saveRemote)
		}
		return
	}
	if ui.Button(c.Part("save"), save).Outline().Disabled(!r.editable() || r.saving || !dirty).Clicked() {
		c.After(a.saveRemote)
	}
	if ui.Button(c.Part("connect"), i18n.Shared(language, "desktop.remote.connect")).Disabled(!r.connectable() || dirty).Clicked() {
		c.After(func() { a.connectRemote("") })
	}
}
