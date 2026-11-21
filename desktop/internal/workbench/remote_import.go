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
	if !r.open || !r.editable() || r.saving || r.connect != nil || r.browser != nil {
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
	generation, kernel := r.generation, a.kernel
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		var motty core.RemoteMottyHosts
		var ssh core.RemoteSSHConfigHosts
		var mottyErr, sshErr error
		if dir, err := os.UserConfigDir(); err == nil {
			motty, mottyErr = kernel.RemoteMottyHosts(ctx, dir, document)
		} else {
			mottyErr = err
		}
		if home, err := os.UserHomeDir(); err == nil {
			ssh, sshErr = kernel.RemoteSSHConfigHosts(ctx, home, document)
		} else {
			sshErr = err
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

// remoteImportView declares the import: where it reads, what it keeps, and the hosts.
func (a *App) remoteImportView(c ui.C, language i18n.Language, m *remoteImporter) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).Fill().Gap(12).PadSides(18, 24, 12, 24).Children(func() {
		ui.Row(c.Part("head")).FillWidth().Items(ui.Center).Gap(12).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.remote.import.title")).FontSize(16).Weight(gfx.WeightSemibold).Grow(1).MinWidth(0).Ellipsis()
			ui.Choice(c.Part("source"), &m.source, []remoteImportSource{remoteImportMotty, remoteImportSSH}, func(source remoteImportSource) string {
				if source == remoteImportSSH {
					return i18n.Shared(language, "desktop.remote.import.source.ssh")
				}
				return i18n.Shared(language, "desktop.remote.import.source.motty")
			})
		})
		from := m.motty.Database
		if m.source == remoteImportSSH {
			from = strings.Join(m.ssh.Files, ", ")
		}
		if from != "" {
			ui.Text(c, i18n.SharedFormat(language, "desktop.remote.import.from", map[string]string{"path": from})).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
		}
		if m.source == remoteImportMotty && m.motty.Unavailable == "" && len(m.motty.Candidates) > 0 {
			ui.Row(c.Part("keep")).FillWidth().Gap(18).Children(func() {
				ui.Checkbox(c.Part("groups"), &m.keepGroups, i18n.Shared(language, "desktop.remote.import.keepGroups")).Disabled(m.applying)
				ui.Checkbox(c.Part("colors"), &m.keepColors, i18n.Shared(language, "desktop.remote.import.keepColors")).Disabled(m.applying)
			})
		}
		if m.err != "" {
			a.remoteNotice(c.Part("error"), icons.CircleX, a.theme.Danger, m.err)
		}
		switch {
		case m.loading:
			ui.Column(c.Part("loading")).FillWidth().Grow(1).Center().Children(func() { ui.Spinner(c.Part("spinner")) })
		case m.source == remoteImportMotty && m.mottyErr != "":
			a.remoteNotice(c.Part("motty-error"), icons.CircleX, a.theme.Danger, m.mottyErr)
		case m.source == remoteImportMotty && m.motty.Unavailable != "":
			a.remoteNotice(c.Part("motty-unavailable"), icons.Info, a.colors.Subtle, remoteMottyUnavailableText(language, m.motty.Unavailable))
		case m.source == remoteImportSSH && m.sshErr != "":
			a.remoteNotice(c.Part("ssh-error"), icons.CircleX, a.theme.Danger, m.sshErr)
		case m.source == remoteImportMotty && len(m.motty.Candidates) == 0, m.source == remoteImportSSH && len(m.ssh.Hosts) == 0:
			a.remoteNotice(c.Part("empty"), icons.Info, a.colors.Subtle, i18n.Shared(language, "desktop.remote.import.empty"))
		default:
			a.remoteImportList(c.Part("hosts"), language, m)
		}
	})
}

// remoteImportList declares the hosts of the source shown, each with its box.
func (a *App) remoteImportList(c ui.C, language i18n.Language, m *remoteImporter) {
	type item struct {
		name, address, system string
		color                 core.RemoteConnectionColor
		status                core.RemoteImportStatus
		chosen                *bool
		choosable             bool
		detail                string
	}
	var items []item
	if m.source == remoteImportSSH {
		for index, host := range m.ssh.Hosts {
			address := ""
			if resolved := host.Resolved; resolved != nil {
				address = remoteAddress(core.SSHConnection{Host: resolved.HostName, User: resolved.User, Port: resolved.Port})
			}
			detail := host.ExistingName
			items = append(items, item{name: host.Alias, address: address, status: host.Status, chosen: &m.sshChosen[index], choosable: remoteImportable(host.Status), detail: detail})
		}
	} else {
		for index, candidate := range m.motty.Candidates {
			items = append(items, item{name: candidate.Name, address: candidate.Address, system: candidate.System, color: candidate.Color, status: candidate.Status,
				chosen: &m.mottyChosen[index], choosable: remoteMottyChoosable(candidate.Status)})
		}
	}
	small := a.theme.Metrics.FontSizeS
	ui.Scroll(c).FillWidth().Grow(1).Basis(0).MinHeight(0).Radius(6).Stroke(1, a.colors.Line).Children(func() {
		ui.Column(c).FillWidth().Children(func() {
			for index, host := range items {
				k := c.KeyInt(index)
				if index > 0 {
					ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
				}
				ui.Row(k).FillWidth().Height(remoteRowHeight).Items(ui.Center).Gap(10).PadX(12).Children(func() {
					ui.Checkbox(k.Part("pick"), host.chosen, "").Label(host.name).Shrink(0).Disabled(!host.choosable || m.applying)
					mark := ""
					if host.system != "" {
						mark = remoteSystemMark(&remoteProbeOutcome{result: core.RemoteProbeResult{Host: &core.RemoteProbedHost{System: host.system}}})
					}
					a.remoteTile(k.Part("tile"), mark, host.color, 26, 10)
					color := a.colors.Text
					if !host.choosable {
						color = a.colors.Subtle
					}
					ui.Column(k).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
						ui.Text(k, host.name).Weight(gfx.WeightMedium).Color(color).Ellipsis().MinWidth(0)
						if host.address != "" {
							ui.Text(k, host.address).Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
						}
					})
					statusColor := a.colors.Subtle
					switch host.status {
					case core.RemoteImportable:
						statusColor = a.colors.Success
					case core.RemoteImportPartial:
						statusColor = a.colors.Warning
					}
					a.remotePill(k.Part("status"), remoteImportStatusName(language, host.status), statusColor)
				})
			}
		})
	})
}

// remoteImportFooter declares how many hosts are chosen and the buttons that import them or go
// back.
func (a *App) remoteImportFooter(c ui.C, language i18n.Language, m *remoteImporter) {
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		count := m.chosen()
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.import.footer", map[string]string{"count": strconv.Itoa(count)})).
			FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).MinWidth(0).Ellipsis()
		if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Disabled(m.applying).Clicked() {
			c.After(a.leaveRemoteImport)
		}
		label := i18n.Shared(language, "desktop.remote.import.apply")
		if m.applying {
			label = i18n.Shared(language, "desktop.remote.import.applying")
		}
		if ui.Button(c.Part("apply"), label).Icon(icons.Download).Disabled(m.loading || m.applying || count == 0).Clicked() {
			c.After(a.applyRemoteImport)
		}
	})
}
