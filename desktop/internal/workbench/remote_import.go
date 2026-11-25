package workbench

import (
	"context"
	"os"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Import saves hosts other tools already know: Motty's (its config.db under the user's
// configuration directory) and the Host names of ~/.ssh/config. Core reads both and says what
// each host would become and why one cannot be imported; Motty's passwords and keys stay in
// Motty, which keeps them apart from config.db, and are never read. The page lists them with the
// importable ones chosen, and one edit saves the chosen ones. A Motty host already saved can
// still give the saved one its color and group.

// remoteImportSource is where an import reads hosts.
type remoteImportSource int

const (
	remoteImportMotty remoteImportSource = iota
	remoteImportSSH
)

// remoteImporter is the import the window shows.
type remoteImporter struct {
	source   remoteImportSource
	loading  bool
	motty    core.RemoteMottyHosts
	ssh      core.RemoteSSHConfigHosts
	mottyErr string
	sshErr   string
	// mottyChosen and sshChosen are the hosts chosen to import, by index.
	mottyChosen []bool
	sshChosen   []bool
	keepGroups  bool
	keepColors  bool
	applying    bool
	err         string
	// opened is the Key of the Motty host whose settings show, or "".
	opened string
}

// remoteMottyChoosable says whether a Motty host can be chosen: to import, or to give the saved
// one its color and group.
func remoteMottyChoosable(status core.RemoteImportStatus) bool {
	return remoteImportable(status) || status == core.RemoteImportExists
}

// openRemoteImport shows the hosts source holds.
func (a *App) openRemoteImport(source remoteImportSource) {
	r := &a.remote
	r.importMenu = false
	if !r.open || !r.editable() || r.saving || r.connect != nil || !a.leaveRemoteFlows() {
		return
	}
	a.performed("remote.import.open", surfaceButton)
	r.stopProbe()
	r.steps = nil
	m := &remoteImporter{source: source, loading: true, keepGroups: true, keepColors: true}
	r.importer = m
	document, err := r.source.Document()
	if err != nil {
		a.operationFailed("remote_import_read", documentLogError(err))
		m.loading = false
		m.err = i18n.SharedFormat(a.language(), "desktop.remote.import.failed", map[string]string{"reason": documentLogError(err).Error()})
		return
	}
	generation, kernel, root := r.generation, a.kernel, a.globalToolchainRoot()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		var motty core.RemoteMottyHosts
		var ssh core.RemoteSSHConfigHosts
		var mottyErr, sshErr error
		if dir, err := os.UserConfigDir(); err == nil {
			motty, mottyErr = kernel.RemoteMottyHosts(ctx, dir, document)
		} else {
			mottyErr = err
		}
		if home, err := os.UserHomeDir(); err != nil {
			sshErr = err
		} else if preferences, err := remotePreferencesDocument(ctx, kernel, root); err != nil {
			sshErr = err
		} else {
			ssh, sshErr = kernel.RemoteSSHConfigHosts(ctx, home, document, preferences)
		}
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.importer != m {
				// log-exempt: 用户取消：窗口已关闭或已离开导入。
				return
			}
			language := a.language()
			m.loading, m.motty, m.ssh = false, motty, ssh
			if mottyErr != nil {
				a.operationFailed("remote_import_motty", documentLogError(mottyErr))
				m.mottyErr = i18n.SharedFormat(language, "desktop.remote.import.failed", map[string]string{"reason": documentLogError(mottyErr).Error()})
			}
			if sshErr != nil {
				a.operationFailed("remote_import_ssh_config", documentLogError(sshErr))
				m.sshErr = i18n.SharedFormat(language, "desktop.remote.import.failed", map[string]string{"reason": documentLogError(sshErr).Error()})
			}
			m.mottyChosen = make([]bool, len(motty.Candidates))
			for index, candidate := range motty.Candidates {
				m.mottyChosen[index] = remoteImportable(candidate.Status)
			}
			m.sshChosen = make([]bool, len(ssh.Hosts))
			for index, host := range ssh.Hosts {
				m.sshChosen[index] = remoteImportable(host.Status)
			}
		}
	})
}

// leaveRemoteImport goes back to the list.
func (a *App) leaveRemoteImport() {
	a.remote.importer = nil
}

// chosen counts the hosts chosen in the source shown.
func (m *remoteImporter) chosen() int {
	chosen := m.mottyChosen
	if m.source == remoteImportSSH {
		chosen = m.sshChosen
	}
	count := 0
	for _, on := range chosen {
		if on {
			count++
		}
	}
	return count
}

// edit is the edit that saves the chosen hosts of the source shown.
func (m *remoteImporter) edit() core.RemoteConnectionImport {
	var edit core.RemoteConnectionImport
	if m.source == remoteImportSSH {
		for index, host := range m.ssh.Hosts {
			if index < len(m.sshChosen) && m.sshChosen[index] && remoteImportable(host.Status) {
				edit.Entries = append(edit.Entries, core.RemoteConnectionSave{Name: host.Alias, Connection: core.SSHConnection{Host: host.Alias}})
			}
		}
		return edit
	}
	for index, candidate := range m.motty.Candidates {
		if index >= len(m.mottyChosen) || !m.mottyChosen[index] {
			continue
		}
		var color core.RemoteConnectionColor
		var group string
		if m.keepColors {
			color = candidate.Color
		}
		if m.keepGroups {
			group = candidate.Group
		}
		switch {
		case candidate.Status == core.RemoteImportExists && candidate.ExistingID != "":
			if color != "" || group != "" {
				edit.Fills = append(edit.Fills, core.RemoteConnectionFill{ID: candidate.ExistingID, Color: color, Group: group})
			}
		case remoteImportable(candidate.Status) && candidate.Connection != nil:
			edit.Entries = append(edit.Entries, core.RemoteConnectionSave{Name: candidate.Name, Connection: *candidate.Connection, Color: color, Group: group})
		}
	}
	return edit
}

// applyRemoteImport saves the chosen hosts and shows the first one saved.
func (a *App) applyRemoteImport() {
	r := &a.remote
	m := r.importer
	if m == nil || m.loading || m.applying || !r.editable() {
		return
	}
	edit := m.edit()
	if len(edit.Entries) == 0 && len(edit.Fills) == 0 {
		return
	}
	a.performed("remote.import.apply", surfaceButton)
	m.applying, m.err = true, ""
	r.saving = true
	source, generation, kernel := r.source, r.generation, a.kernel
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		after, publication, committed, err := source.Apply(ctx, kernel, core.RemoteConnectionEdit{Import: &edit})
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口已关闭，导入已按上面的结果写入或放弃。
				return
			}
			r.saving = false
			m.applying = false
			if err != nil {
				a.operationFailed("remote_import_apply", documentLogError(err))
				m.err = i18n.SharedFormat(a.language(), "desktop.remote.import.failed", map[string]string{"reason": documentLogError(err).Error()})
				return
			}
			if !committed {
				a.operationRejected("remote_import_apply", "not_committed")
			}
			r.setSource(after)
			a.loadRemoteImportCounts()
			if r.importer == m {
				r.importer = nil
			}
			if len(publication.IDs) > 0 {
				r.selectEntry(publication.IDs[0])
			} else {
				r.selectFirst()
			}
			count := len(edit.Entries) + len(edit.Fills)
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.remote.import.done", map[string]string{"count": strconv.Itoa(count)}))
		}
	})
}

// remoteImportStatusName names what an import does with a host.
func remoteImportStatusName(language i18n.Language, status core.RemoteImportStatus) string {
	switch status {
	case core.RemoteImportable:
		return i18n.Shared(language, "desktop.remote.import.status.importable")
	case core.RemoteImportPartial:
		return i18n.Shared(language, "desktop.remote.import.status.partial")
	case core.RemoteImportExists:
		return i18n.Shared(language, "desktop.remote.import.status.exists")
	case core.RemoteImportPattern:
		return i18n.Shared(language, "desktop.remote.import.status.pattern")
	case core.RemoteImportInvalid:
		return i18n.Shared(language, "desktop.remote.import.status.invalid")
	case core.RemoteImportUnreadable:
		return i18n.Shared(language, "desktop.remote.import.status.unreadable")
	}
	return i18n.Shared(language, "desktop.remote.import.status.unsupported")
}

// remoteMottyUnavailableText says why Motty's hosts could not be read.
func remoteMottyUnavailableText(language i18n.Language, unavailable core.RemoteMottyUnavailable) string {
	switch unavailable {
	case core.RemoteMottyMissing:
		return i18n.Shared(language, "desktop.remote.import.mottyMissing")
	case core.RemoteMottyTooLarge:
		return i18n.Shared(language, "desktop.remote.import.mottyTooLarge")
	case core.RemoteMottyUnsupportedFormat:
		return i18n.Shared(language, "desktop.remote.import.mottyUnsupported")
	}
	return i18n.Shared(language, "desktop.remote.import.mottyUnreadable")
}

// remoteImportView declares the import: the source switch with what it reads, Motty's summary
// with what an import keeps, and the hosts as a table.
func (a *App) remoteImportView(c ui.C, language i18n.Language, m *remoteImporter) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).Fill().Gap(14).PadSides(18, 22, 12, 22).Children(func() {
		ui.Row(c.Part("head")).FillWidth().Items(ui.Center).Gap(10).Children(func() {
			ui.Choice(c.Part("source"), &m.source, []remoteImportSource{remoteImportMotty, remoteImportSSH}, func(source remoteImportSource) string {
				if source == remoteImportSSH {
					return i18n.Shared(language, "desktop.remote.import.source.ssh")
				}
				return i18n.Shared(language, "desktop.remote.import.source.motty")
			}).Disabled(m.applying)
			note := i18n.Shared(language, "desktop.remote.import.mottyNote")
			help := ""
			if m.motty.Database != "" {
				help = i18n.SharedFormat(language, "desktop.remote.import.mottyHelp", map[string]string{"path": m.motty.Database})
			}
			if m.source == remoteImportSSH {
				note = i18n.Shared(language, "desktop.remote.import.sshNote")
				help = ""
				if len(m.ssh.Files) > 0 {
					help = i18n.SharedFormat(language, "desktop.remote.import.sshHelp", map[string]string{"files": strings.Join(m.ssh.Files, ", ")})
				}
			}
			ui.Text(c, note).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			if help != "" {
				a.remoteHelp(c.Part("note"), help)
			}
			ui.Spacer(c)
			if ui.Button(c.Part("reload"), i18n.Shared(language, "desktop.remote.import.reload")).Link().Small().Disabled(m.loading || m.applying).Clicked() {
				source := m.source
				c.After(func() { a.openRemoteImport(source) })
			}
		})
		if m.err != "" {
			a.remoteNotice(c.Part("error"), icons.CircleX, a.theme.Danger, m.err)
		}
		switch {
		case m.loading:
			ui.Column(c.Part("loading")).FillWidth().Grow(1).Center().Children(func() { ui.Spinner(c) })
		case m.source == remoteImportMotty && m.mottyErr != "":
			a.remoteNotice(c.Part("motty-error"), icons.CircleX, a.theme.Danger, m.mottyErr)
		case m.source == remoteImportMotty && m.motty.Unavailable != "":
			a.remoteNotice(c.Part("motty-unavailable"), icons.Info, a.colors.Subtle, remoteMottyUnavailableText(language, m.motty.Unavailable))
		case m.source == remoteImportSSH && m.sshErr != "":
			a.remoteNotice(c.Part("ssh-error"), icons.CircleX, a.theme.Danger, m.sshErr)
		case m.source == remoteImportMotty && len(m.motty.Candidates) == 0, m.source == remoteImportSSH && len(m.ssh.Hosts) == 0:
			a.remoteNotice(c.Part("empty"), icons.Info, a.colors.Subtle, i18n.Shared(language, "desktop.remote.import.empty"))
		case m.source == remoteImportSSH:
			a.remoteSSHImportTable(c.Part("ssh"), language, m)
		default:
			a.remoteMottySummary(c.Part("summary"), language, m)
			a.remoteMottyImportTable(c.Part("motty"), language, m)
		}
	})
}

// remoteMottySummary declares what Motty's database holds, and whether the import keeps its
// groups and colors.
func (a *App) remoteMottySummary(c ui.C, language i18n.Language, m *remoteImporter) {
	small := a.theme.Metrics.FontSizeS
	ui.Row(c).FillWidth().Items(ui.Center).Gap(10).PadSides(10, 12, 10, 12).Radius(8).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
		ui.Row(c.Part("mark")).Size(24, 24).Shrink(0).Center().Radius(5).Background(gfx.RGB24(0x111111)).Children(func() {
			ui.Text(c, "M").FontSize(12).Weight(gfx.WeightBold).Color(gfx.RGB24(0xFFFFFF))
		})
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.import.mottyFound", map[string]string{
			"hosts": strconv.Itoa(len(m.motty.Candidates)), "groups": strconv.Itoa(len(m.motty.Groups)), "format": m.motty.Format,
		})).FontSize(small).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(c)
		ui.Checkbox(c.Part("groups"), &m.keepGroups, i18n.Shared(language, "desktop.remote.import.keepGroups")).Disabled(m.applying)
		ui.Checkbox(c.Part("colors"), &m.keepColors, i18n.Shared(language, "desktop.remote.import.keepColors")).Disabled(m.applying)
	})
}

// remoteImportHeader declares a table's column names over a line; a width of 0 grows.
func (a *App) remoteImportHeader(c ui.C, lead, trail float32, columns []string, widths []float32) {
	ui.Row(c).FillWidth().Height(30).Shrink(0).Items(ui.Center).Gap(10).PadX(10).Children(func() {
		ui.Row(c.Part("lead")).Width(lead).Shrink(0)
		for index, column := range columns {
			cell := ui.Text(c, column).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightMedium).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
			if widths[index] == 0 {
				cell.Grow(1).Basis(0)
			} else {
				cell.Width(widths[index]).Shrink(0)
			}
		}
		if trail > 0 {
			ui.Row(c.Part("trail")).Width(trail).Shrink(0)
		}
	})
	ui.Row(c.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
}

// remoteImportTag declares what an import does with a host, tinted by it.
func (a *App) remoteImportTag(c ui.C, text string, status core.RemoteImportStatus) {
	color := a.colors.Subtle
	switch status {
	case core.RemoteImportable:
		color = a.colors.Success
	case core.RemoteImportPartial:
		color = a.colors.Warning
	case core.RemoteImportInvalid, core.RemoteImportUnreadable:
		color = a.theme.Danger
	}
	a.remoteTag(c, text, color)
}

// remoteTag declares a small rounded tag tinted with color.
func (a *App) remoteTag(c ui.C, text string, color gfx.Color) {
	ui.Row(c).Shrink(0).Height(20).Items(ui.Center).PadX(8).Radius(10).Background(color.WithAlpha(0.13)).Children(func() {
		ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(color).Ellipsis().MinWidth(0)
	})
}

// remoteSSHImportTable declares the Host names of ~/.ssh/config: each alias, what `ssh -G`
// resolves it to, and what the import does with it.
func (a *App) remoteSSHImportTable(c ui.C, language i18n.Language, m *remoteImporter) {
	small := a.theme.Metrics.FontSizeS
	widths := []float32{140, 0, 170}
	ui.Column(c).FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
		a.remoteImportHeader(c.Part("header"), 22, 0, []string{
			i18n.Shared(language, "desktop.remote.import.column.alias"),
			i18n.Shared(language, "desktop.remote.import.column.resolved"),
			i18n.Shared(language, "desktop.remote.import.column.result"),
		}, widths)
		ui.Scroll(c.Part("rows")).FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
			ui.Column(c).FillWidth().Children(func() {
				for index, host := range m.ssh.Hosts {
					k := c.KeyInt(index)
					choosable := remoteImportable(host.Status)
					color := a.colors.Text
					if !choosable {
						color = a.colors.Subtle
					}
					ui.Row(k).FillWidth().MinHeight(38).Items(ui.Center).Gap(10).PadSides(8, 10, 8, 10).Children(func() {
						ui.Row(k.Part("pick")).Width(22).Shrink(0).Children(func() {
							ui.Checkbox(k.Part("box"), &m.sshChosen[index], "").Label(host.Alias).Disabled(!choosable || m.applying)
						})
						ui.Text(c, host.Alias).Mono().FontSize(small).Color(color).Width(widths[0]).Shrink(0).Ellipsis()
						ui.Column(k).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
							switch {
							case host.Status == core.RemoteImportPattern:
								ui.Text(c, i18n.Shared(language, "desktop.remote.import.patternNote")).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
							case host.Resolved != nil:
								resolved := host.Resolved
								ui.Text(c, remoteAddress(core.SSHConnection{Host: resolved.HostName, User: resolved.User, Port: resolved.Port})).
									Mono().FontSize(small).Color(color).Ellipsis().MinWidth(0)
							}
							if len(host.UsedAsJumpBy) > 0 {
								ui.Text(c, i18n.SharedFormat(language, "desktop.remote.import.jumpFor", map[string]string{"hosts": strings.Join(host.UsedAsJumpBy, ", ")})).
									Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
							}
						})
						status := remoteImportStatusName(language, host.Status)
						if host.Status == core.RemoteImportExists && host.ExistingName != "" {
							status = i18n.SharedFormat(language, "desktop.remote.import.status.existsAs", map[string]string{"name": host.ExistingName})
						}
						ui.Row(k.Part("result")).Width(widths[2]).Shrink(0).Children(func() {
							a.remoteImportTag(k.Part("status"), status, host.Status)
						})
					})
					ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
				}
			})
		})
	})
}

// remoteMottyImportTable declares Motty's hosts: each with its color, system and address, its
// group, what the import does with it, and, opened, how each of its settings is imported.
func (a *App) remoteMottyImportTable(c ui.C, language i18n.Language, m *remoteImporter) {
	small := a.theme.Metrics.FontSizeS
	widths := []float32{0, 90, 210}
	ui.Column(c).FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
		a.remoteImportHeader(c.Part("header"), 22+10+10+10+26, 20, []string{
			i18n.Shared(language, "desktop.remote.import.column.host"),
			i18n.Shared(language, "desktop.remote.import.column.group"),
			i18n.Shared(language, "desktop.remote.import.column.result"),
		}, widths)
		ui.Scroll(c.Part("rows")).FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
			ui.Column(c).FillWidth().Children(func() {
				for index, candidate := range m.motty.Candidates {
					k := c.KeyInt(index)
					choosable := remoteMottyChoosable(candidate.Status)
					open := m.opened == candidate.Key
					color := a.colors.Text
					if !choosable {
						color = a.colors.Subtle
					}
					ui.Row(k).FillWidth().MinHeight(44).Items(ui.Center).Gap(10).PadSides(6, 10, 6, 10).Children(func() {
						ui.Row(k.Part("pick")).Width(22).Shrink(0).Children(func() {
							ui.Checkbox(k.Part("box"), &m.mottyChosen[index], "").Label(candidate.Name).Disabled(!choosable || m.applying)
						})
						ui.Row(k.Part("color")).Width(10).Shrink(0).Center().Children(func() {
							if tint, marked := remoteColor(a.colors.Dark, candidate.Color); marked {
								a.remoteDot(k.Part("dot"), tint, 8)
							}
						})
						mark := ""
						if candidate.System != "" {
							mark = remoteSystemMark(&remoteProbeOutcome{result: core.RemoteProbeResult{Host: &core.RemoteProbedHost{System: candidate.System}}})
						}
						a.remoteTile(k.Part("tile"), mark, candidate.Name, candidate.Color, 26, 10)
						ui.Column(k).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
							ui.Text(c, candidate.Name).Weight(gfx.WeightMedium).Color(color).Ellipsis().MinWidth(0)
							if candidate.Address != "" {
								ui.Text(c, candidate.Address).Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
							}
						})
						group := candidate.Group
						if group == "" {
							group = "—"
						}
						ui.Text(c, group).FontSize(small).Color(color).Width(widths[1]).Shrink(0).Ellipsis()
						ui.Row(k.Part("result")).Width(widths[2]).Shrink(0).Items(ui.Center).Gap(6).Children(func() {
							a.remoteImportTag(k.Part("status"), remoteImportStatusName(language, candidate.Status), candidate.Status)
							if candidate.Status == core.RemoteImportExists && m.mottyChosen[index] {
								ui.Text(c, i18n.Shared(language, "desktop.remote.import.fill")).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
							}
						})
						icon := icons.ChevronRight
						if open {
							icon = icons.ChevronDown
						}
						if len(candidate.Fields) > 0 {
							if ui.Button(k.Part("more"), i18n.Shared(language, "desktop.remote.import.details")).Icon(icon).IconOnly().Ghost().Size(20, 20).Shrink(0).Clicked() {
								key := candidate.Key
								c.After(func() {
									if m.opened == key {
										m.opened = ""
									} else {
										m.opened = key
									}
								})
							}
						} else {
							ui.Row(k.Part("more")).Width(20).Shrink(0)
						}
					})
					if open {
						a.remoteMottyFields(k.Part("fields"), language, candidate.Fields)
					}
					ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
				}
			})
		})
	})
}

// remoteMottyFields declares how each of a Motty host's settings is imported: Motty's setting and
// value, the connection setting it becomes or why it is not imported.
func (a *App) remoteMottyFields(c ui.C, language i18n.Language, fields []core.RemoteMottyField) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().PadSides(6, 10, 10, 52).Background(a.colors.Hover).Children(func() {
		for index, field := range fields {
			if index > 0 {
				ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			}
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().MinHeight(26).Items(ui.Center).Gap(10).PadY(3).Children(func() {
				ui.Text(c, field.Motty).Mono().FontSize(small).Color(a.colors.Subtle).Grow(1).Basis(0).MinWidth(0).Ellipsis()
				value := field.Value
				if value == "" {
					value = "—"
				}
				ui.Text(c, value).Mono().FontSize(small).Grow(1).Basis(0).MinWidth(0).Ellipsis()
				ui.Text(c, "→").FontSize(small).Color(a.colors.Subtle).Shrink(0)
				if field.Lithe != "" {
					ui.Text(c, remoteMottyFieldName(language, field.Lithe)).FontSize(small).Grow(1.6).Basis(0).MinWidth(0).Ellipsis()
				} else {
					ui.Text(c, remoteMottySkipText(language, field.Skip)).FontSize(small).Color(a.colors.Subtle).Grow(1.6).Basis(0).MinWidth(0).Ellipsis()
				}
				ui.Row(k.Part("tag")).Width(110).Shrink(0).Children(func() {
					ui.Spacer(c)
					if field.Lithe != "" {
						a.remoteTag(k.Part("imported"), i18n.Shared(language, "desktop.remote.import.field.imported"), a.colors.Success)
					} else {
						a.remoteTag(k.Part("skipped"), i18n.Shared(language, "desktop.remote.import.field.skipped"), a.theme.Danger)
					}
				})
			})
		}
	})
}

// remoteMottyFieldName names the connection setting a Motty setting becomes, as the form names it.
func remoteMottyFieldName(language i18n.Language, field string) string {
	switch field {
	case "name":
		return i18n.Shared(language, "desktop.remote.name")
	case "host":
		return i18n.Shared(language, "desktop.remote.host")
	case "user":
		return i18n.Shared(language, "desktop.remote.user")
	case "port":
		return i18n.Shared(language, "desktop.remote.port")
	case "color":
		return i18n.Shared(language, "desktop.remote.color")
	case "group":
		return i18n.Shared(language, "desktop.remote.group")
	case "identityFile":
		return i18n.Shared(language, "desktop.remote.identityFile")
	case "keepAliveSeconds":
		return i18n.Shared(language, "desktop.remote.keepAlive")
	case "proxyJump":
		return i18n.Shared(language, "desktop.remote.proxyJump")
	case "authentication":
		return i18n.Shared(language, "desktop.remote.import.field.authentication")
	}
	return field
}

// remoteMottySkipText says why a Motty setting is not imported.
func remoteMottySkipText(language i18n.Language, skip core.RemoteMottySkip) string {
	switch skip {
	case core.RemoteMottySkipSecret:
		return i18n.Shared(language, "desktop.remote.import.skip.secret")
	case core.RemoteMottySkipProtocol:
		return i18n.Shared(language, "desktop.remote.import.skip.protocol")
	case core.RemoteMottySkipCommand:
		return i18n.Shared(language, "desktop.remote.import.skip.command")
	case core.RemoteMottySkipKerberos:
		return i18n.Shared(language, "desktop.remote.import.skip.kerberos")
	case core.RemoteMottySkipExtraKey:
		return i18n.Shared(language, "desktop.remote.import.skip.extraKey")
	case core.RemoteMottySkipInvalid:
		return i18n.Shared(language, "desktop.remote.import.skip.invalid")
	}
	return i18n.Shared(language, "desktop.remote.import.skip.noSetting")
}

// remoteImportNewGroups lists the groups the chosen Motty hosts bring that the list does not have,
// in Motty's order.
func (a *App) remoteImportNewGroups(m *remoteImporter) []string {
	if m.source != remoteImportMotty || !m.keepGroups {
		return nil
	}
	have := map[string]bool{}
	for _, group := range a.remote.groups {
		have[group] = true
	}
	var groups []string
	for index, candidate := range m.motty.Candidates {
		if index < len(m.mottyChosen) && m.mottyChosen[index] && candidate.Group != "" && !have[candidate.Group] {
			have[candidate.Group] = true
			groups = append(groups, candidate.Group)
		}
	}
	return groups
}

// remoteImportFooter declares what the import saves and the buttons that import or go back.
func (a *App) remoteImportFooter(c ui.C, language i18n.Language, m *remoteImporter) {
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		count := m.chosen()
		text := i18n.SharedFormat(language, "desktop.remote.import.footer", map[string]string{"count": strconv.Itoa(count)})
		if groups := a.remoteImportNewGroups(m); len(groups) > 0 {
			text = i18n.SharedFormat(language, "desktop.remote.import.footerGroups", map[string]string{
				"count": strconv.Itoa(count), "groupCount": strconv.Itoa(len(groups)), "groups": strings.Join(groups, ", "),
			})
		}
		ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).MinWidth(0).Ellipsis()
		if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Disabled(m.applying).Clicked() {
			c.After(a.leaveRemoteImport)
		}
		label := i18n.Shared(language, "desktop.remote.import.apply")
		if m.applying {
			label = i18n.Shared(language, "desktop.remote.import.applying")
		}
		if ui.Button(c.Part("apply"), label).Disabled(m.loading || m.applying || count == 0).Clicked() {
			c.After(a.applyRemoteImport)
		}
	})
}
