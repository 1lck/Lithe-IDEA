package workbench

import (
	"context"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds what the Remote Development window's list and pages read besides the saved
// connections: the search, the folded groups, the connections open in a window, what OpenSSH
// resolves for a connection, the address typed on the empty page and the counts of the hosts the
// other tools hold to import. All of it is asked of Core; nothing here is written anywhere.

// remoteEffective is what OpenSSH resolves for a connection, or why it could not tell.
type remoteEffective struct {
	settings core.RemoteEffectiveSettings
	err      error
}

// remoteImportCounts are how many hosts Motty and ~/.ssh/config hold that can be imported, once
// loaded.
type remoteImportCounts struct {
	loaded           bool
	motty, sshConfig int
}

// remoteFormValues are the effective values the form's empty fields show as "Auto (value)", ""
// for one not known.
type remoteFormValues struct {
	port, user, timeout, keepAlive string
}

// buildRows lays out the list from the sections Core found for the query while one is typed, else
// from the source's, under a heading for each group when any section names one, followed by the
// WSL distributions (remote_wsl.go) and the running containers (remote_container.go). A folded
// group keeps its heading only, and a search unfolds every group.
func (r *remoteState) buildRows() {
	r.rows = nil
	byID := make(map[string]*core.SavedRemoteConnection, len(r.source.Connections))
	for index := range r.source.Connections {
		byID[r.source.Connections[index].ID] = &r.source.Connections[index]
	}
	sections := r.source.Sections
	if r.found != nil {
		sections = r.found
	}
	headed := slices.ContainsFunc(r.source.Sections, func(section core.RemoteConnectionSection) bool { return section.Group != nil })
	for _, section := range sections {
		group := ""
		if section.Group != nil {
			group = *section.Group
		}
		if headed {
			r.rows = append(r.rows, remoteListRow{heading: true, group: group, count: len(section.IDs)})
			if r.found == nil && r.collapsed[group] {
				continue
			}
		}
		for _, id := range section.IDs {
			if entry := byID[id]; entry != nil {
				r.rows = append(r.rows, remoteListRow{entry: entry})
			}
		}
	}
	r.rows = append(r.rows, r.wslRows()...)
	r.rows = append(r.rows, r.containerRows()...)
}

// toggleRemoteGroup folds or unfolds group in the list.
func (a *App) toggleRemoteGroup(group string) {
	r := &a.remote
	if r.collapsed == nil {
		r.collapsed = map[string]bool{}
	}
	r.collapsed[group] = !r.collapsed[group]
	a.performed("remote.connections.group.toggle", surfaceButton)
	r.buildRows()
	r.syncListSelection()
}

// searchRemote asks Core for the connections that match the query and lists only them; an empty
// query lists every connection again.
func (a *App) searchRemote() {
	r := &a.remote
	r.searching++
	query := strings.TrimSpace(r.query.Text())
	if query == "" {
		r.found = nil
		r.buildRows()
		r.syncListSelection()
		return
	}
	document, err := r.source.Document()
	if err != nil {
		a.backgroundFailed("remote_connections_search", documentLogError(err))
		return
	}
	search, generation, kernel := r.searching, r.generation, a.kernel
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		found, err := kernel.SearchRemoteConnections(ctx, document, query)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.searching != search {
				// log-exempt: 用户取消：窗口已关闭或又输入了新的查询，旧结果作废。
				return
			}
			if err != nil {
				a.backgroundFailed("remote_connections_search", err)
				return
			}
			r.found = found.Sections
			if r.found == nil {
				r.found = []core.RemoteConnectionSection{}
			}
			r.buildRows()
			r.syncListSelection()
		}
	})
}

// clearRemoteSearch empties the query and lists every connection again.
func (a *App) clearRemoteSearch() {
	a.remote.query.SetText("")
	a.searchRemote()
}

// remoteLive reports whether the connection id is connected now: a window has it open, or this
// window chooses a folder over its session.
func (a *App) remoteLive(id string) bool {
	return a.remoteWindows(id) > 0 || (a.remote.browser != nil && a.remote.browser.entryID == id)
}

// remoteWindows is how many open windows work in a folder over the saved connection id.
func (a *App) remoteWindows(id string) int {
	return a.remoteWindowsWhere(func(other string) bool { return other == id })
}

// remoteWindowsWhere is how many open windows work in a folder over a connection whose id match
// accepts.
func (a *App) remoteWindowsWhere(match func(id string) bool) int {
	if a.sessions == nil {
		return 0
	}
	count := 0
	for _, w := range a.sessions.list {
		if w.project != nil && w.project.remote != nil && match(w.project.remote.connectionID) &&
			w.project.remote.session != "" && !w.project.remote.closed {
			count++
		}
	}
	return count
}

// remoteLastConnected says when the saved connection last connected, relative to now.
func (a *App) remoteLastConnected(language i18n.Language, entry core.SavedRemoteConnection) string {
	if entry.LastConnectedAt == 0 {
		return i18n.Shared(language, "desktop.remote.neverConnected")
	}
	return relativeGitTime(language, a.now(), time.Unix(int64(entry.LastConnectedAt), 0))
}

// remoteSystemMark is the two letters the list marks a connection's host with, from what its last
// test found ("Ub" for Ubuntu), "" when it was not tested.
func remoteSystemMark(outcome *remoteProbeOutcome) string {
	if outcome == nil || outcome.err != nil || outcome.result.Host == nil {
		return ""
	}
	name := strings.TrimSpace(outcome.result.Host.Details.OperatingSystem)
	if name == "" {
		name = strings.TrimSpace(outcome.result.Host.System)
	}
	runes := []rune(name)
	if len(runes) == 0 {
		return ""
	}
	if len(runes) > 2 {
		runes = runes[:2]
	}
	return strings.ToUpper(string(runes[:1])) + strings.ToLower(string(runes[1:]))
}

// quickRemote has Core split the empty page's user@host:port and starts a new connection with it.
func (a *App) quickRemote() {
	r := &a.remote
	text := strings.TrimSpace(r.quick.Text())
	if text == "" {
		return
	}
	a.performed("remote.connection.quick", surfaceButton)
	generation, kernel := r.generation, a.kernel
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		address, err := kernel.RemoteParseAddress(ctx, text)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口已关闭。
				return
			}
			language := a.language()
			if field, reason, ok := core.RemoteConnectionFieldError(err); ok {
				a.operationRejected("remote_connection_quick", "field_refused")
				r.quickErr = remoteRefusalText(language, remoteFieldRefusal{field: field, reason: reason})
				return
			}
			if err != nil {
				a.operationFailed("remote_connection_quick", err)
				r.quickErr = i18n.SharedFormat(language, "desktop.remote.readFailed", map[string]string{"reason": err.Error()})
				return
			}
			r.quickErr = ""
			r.quick.SetText("")
			r.previous = r.selected
			r.selectNew()
			r.form.host.SetText(address.Host)
			r.form.user.SetText(address.User)
			if address.Port != 0 {
				r.form.port.SetText(strconv.Itoa(int(address.Port)))
			}
		}
	})
}

// copyRemoteAsNew starts a new connection filled from the selected one.
func (a *App) copyRemoteAsNew() {
	r := &a.remote
	entry := r.entry(r.selected)
	if entry == nil {
		return
	}
	a.performed("remote.connection.copy", surfaceMenu)
	copied := *entry
	r.previous = r.selected
	r.resetEditing()
	r.selected, r.editing = "", true
	r.form.fill(copied)
	r.form.name.SetText(i18n.SharedFormat(a.language(), "desktop.remote.copyName", map[string]string{"name": copied.Name}))
	r.syncListSelection()
}

// loadRemoteEffective asks OpenSSH, through Core, what it resolves for connection, once per
// opening of the window.
func (a *App) loadRemoteEffective(connection core.SSHConnection) {
	r := &a.remote
	key := remoteStored(connection)
	if _, asked := r.effective[key]; asked {
		return
	}
	if r.effective == nil {
		r.effective = map[core.SSHConnection]*remoteEffective{}
	}
	r.effective[key] = nil
	generation, kernel, root := r.generation, a.kernel, a.globalToolchainRoot()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		var settings core.RemoteEffectiveSettings
		preferences, err := remotePreferencesDocument(ctx, kernel, root)
		if err == nil {
			settings, err = kernel.RemoteEffectiveSettings(ctx, key, preferences)
		}
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口已关闭，读到的值不再显示。
				return
			}
			if err != nil {
				a.backgroundFailed("remote_effective_settings", err)
			}
			r.effective[key] = &remoteEffective{settings: settings, err: err}
		}
	})
}

// remoteFormEffective is what the form's empty fields fall back to: the effective values of the
// saved connection it edits, once OpenSSH named them.
func (a *App) remoteFormEffective() remoteFormValues {
	r := &a.remote
	entry := r.entry(r.selected)
	if entry == nil {
		return remoteFormValues{}
	}
	known := r.effective[remoteStored(entry.Connection)]
	if known == nil || known.err != nil {
		return remoteFormValues{}
	}
	s := known.settings
	values := remoteFormValues{user: s.User.Value}
	if s.Port.Value != 0 {
		values.port = strconv.FormatUint(uint64(s.Port.Value), 10)
	}
	if s.ConnectTimeoutSeconds.Value != 0 {
		values.timeout = i18n.SharedFormat(a.language(), "desktop.remote.seconds", map[string]string{"count": strconv.FormatUint(uint64(s.ConnectTimeoutSeconds.Value), 10)})
	}
	if s.KeepAliveSeconds.Value != 0 {
		values.keepAlive = i18n.SharedFormat(a.language(), "desktop.remote.seconds", map[string]string{"count": strconv.FormatUint(uint64(s.KeepAliveSeconds.Value), 10)})
	}
	return values
}

// remoteAutoPlaceholder is an empty field's "Auto (value)" when the effective value is known, and
// the field's own placeholder otherwise.
func (a *App) remoteAutoPlaceholder(language i18n.Language, value, fallback string) string {
	if value == "" {
		return fallback
	}
	return i18n.SharedFormat(language, "desktop.remote.auto", map[string]string{"value": value})
}

// loadRemoteImportCounts counts the hosts Motty and ~/.ssh/config hold that can be imported, for
// the empty page's cards and the import menu. Core compares them with the saved list, so a host
// already saved is not counted.
func (a *App) loadRemoteImportCounts() {
	generation, kernel, root := a.remote.generation, a.kernel, a.globalToolchainRoot()
	document, failure := a.remote.source.Document()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		counts := remoteImportCounts{loaded: true}
		if dir, err := os.UserConfigDir(); err == nil {
			hosts, err := kernel.RemoteMottyHosts(ctx, dir, document)
			if err != nil {
				failure = err
			}
			for _, candidate := range hosts.Candidates {
				if remoteImportable(candidate.Status) {
					counts.motty++
				}
			}
		}
		if home, err := os.UserHomeDir(); err == nil {
			preferences, err := remotePreferencesDocument(ctx, kernel, root)
			var hosts core.RemoteSSHConfigHosts
			if err == nil {
				hosts, err = kernel.RemoteSSHConfigHosts(ctx, home, document, preferences)
			}
			if err != nil {
				failure = err
			}
			for _, host := range hosts.Hosts {
				if remoteImportable(host.Status) {
					counts.sshConfig++
				}
			}
		}
		return func(a *App) {
			if failure != nil {
				a.backgroundFailed("remote_import_count", failure)
			}
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口已关闭，计数不再显示。
				return
			}
			r.imports = counts
		}
	})
}

// remoteImportable says whether an import of status adds a connection.
func remoteImportable(status core.RemoteImportStatus) bool {
	return status == core.RemoteImportable || status == core.RemoteImportPartial
}

// remoteHopList splits the form's ProxyJump into its jump hosts, in order.
func remoteHopList(text string) []string {
	var hops []string
	for _, hop := range strings.Split(text, ",") {
		if hop = strings.TrimSpace(hop); hop != "" {
			hops = append(hops, hop)
		}
	}
	return hops
}

// addRemoteHop adds the jump hosts typed in the hop field after the form's others.
func (a *App) addRemoteHop() {
	r := &a.remote
	added := remoteHopList(r.hop.Text())
	if len(added) == 0 {
		return
	}
	r.form.proxyJump.SetText(strings.Join(append(remoteHopList(r.form.proxyJump.Text()), added...), ","))
	r.hop.SetText("")
}

// remoteHops declares the form's jump hosts as chips with a field that adds one, and under them
// the route a connection takes: this computer, each jump host, then the host.
func (a *App) remoteHops(c ui.C, language i18n.Language, disabled bool) {
	r := &a.remote
	f := &r.form
	hops := remoteHopList(f.proxyJump.Text())
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		ui.Flow(c.Part("hops")).FillWidth().Gap(6).Children(func() {
			for index, hop := range hops {
				k := c.KeyInt(index)
				ui.Row(k).Height(a.theme.Metrics.ControlHeight).Shrink(0).Items(ui.Center).Gap(2).PadSides(0, 3, 0, 9).
					Radius(a.theme.Metrics.RadiusItem()).Background(a.colors.Hover).Stroke(1, a.colors.TabIdleBorder).Children(func() {
					ui.Text(c, hop).Mono().FontSize(small)
					remove := ui.Button(k.Part("remove"), i18n.SharedFormat(language, "desktop.remote.hopRemove", map[string]string{"host": hop})).
						Icon(icons.X).IconOnly().Ghost().Size(18, 18).Disabled(disabled)
					if remove.Clicked() {
						at := index
						c.After(func() {
							f.proxyJump.SetText(strings.Join(slices.Delete(slices.Clone(hops), at, at+1), ","))
						})
					}
				})
			}
			field := ui.TextField(c.Part("hop"), &r.hop, i18n.Shared(language, "desktop.remote.hopAdd"), i18n.Shared(language, "desktop.remote.hopPlaceholder")).
				Width(240).Icon(icons.Plus).Disabled(disabled)
			if field.Submitted() {
				c.After(a.addRemoteHop)
			}
		})
		if len(hops) == 0 {
			return
		}
		ui.Row(c.Part("route")).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			step := func(text string, color gfx.Color) {
				ui.Icon(c, icons.ChevronRight).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
				ui.Text(c, text).Mono().FontSize(small).Color(color).Ellipsis().Shrink(1).MinWidth(0)
			}
			ui.Text(c, i18n.Shared(language, "desktop.remote.thisComputer")).FontSize(small).Color(a.colors.Subtle).Shrink(0)
			for _, hop := range hops {
				step(hop, a.colors.Subtle)
			}
			target := strings.TrimSpace(f.host.Text())
			if user := strings.TrimSpace(f.user.Text()); user != "" && target != "" {
				target = user + "@" + target
			}
			if target != "" {
				step(target, a.colors.Accent)
			}
		})
	})
}
